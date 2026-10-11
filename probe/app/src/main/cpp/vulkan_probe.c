// Vulkan 探测: 只把结果拼成一段文本返回, 尽量少跟 Kotlin 交互。
// 用的都是 Vulkan 1.0 核心接口, 不依赖任何扩展, 所以在原版厂商驱动和
// PanVK 上都能跑, 方便替换前后对比。
#include <jni.h>
#include <android/log.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>

#define TAG "panvkprobe"
#define REPORT_CAP 65536

static char g_report[REPORT_CAP];
static size_t g_off;

static void ap(const char *fmt, ...)
{
	va_list ap;
	int n;

	if (g_off >= REPORT_CAP - 1)
		return;
	va_start(ap, fmt);
	n = vsnprintf(g_report + g_off, REPORT_CAP - g_off, fmt, ap);
	va_end(ap);
	if (n > 0)
		g_off += (size_t)n;
	if (g_off >= REPORT_CAP)
		g_off = REPORT_CAP - 1;
	g_report[g_off] = '\0';
}

static double now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static const char *driver_name(VkDriverId id)
{
	switch (id) {
	case VK_DRIVER_ID_AMD_PROPRIETARY: return "amd-proprietary";
	case VK_DRIVER_ID_AMD_OPEN_SOURCE: return "amd-open";
	case VK_DRIVER_ID_MESA_RADV: return "mesa-radv";
	case VK_DRIVER_ID_NVIDIA_PROPRIETARY: return "nvidia";
	case VK_DRIVER_ID_INTEL_PROPRIETARY_WINDOWS: return "intel-proprietary";
	case VK_DRIVER_ID_INTEL_OPEN_SOURCE_MESA: return "intel-mesa";
	case VK_DRIVER_ID_IMAGINATION_PROPRIETARY: return "imagination";
	case VK_DRIVER_ID_QUALCOMM_PROPRIETARY: return "qualcomm";
	case VK_DRIVER_ID_ARM_PROPRIETARY: return "arm";
	case VK_DRIVER_ID_GOOGLE_SWIFTSHADER: return "swiftshader";
	case VK_DRIVER_ID_GGP_PROPRIETARY: return "ggp";
	case VK_DRIVER_ID_BROADCOM_PROPRIETARY: return "broadcom";
	case VK_DRIVER_ID_MESA_LLVMPIPE: return "mesa-llvmpipe";
	case VK_DRIVER_ID_MOLTENVK: return "moltenvk";
	case VK_DRIVER_ID_COREAVI_PROPRIETARY: return "coreavi";
	case VK_DRIVER_ID_JUICE_PROPRIETARY: return "juice";
	case VK_DRIVER_ID_VERISILICON_PROPRIETARY: return "verisilicon";
	case VK_DRIVER_ID_MESA_TURNIP: return "mesa-turnip";
	case VK_DRIVER_ID_MESA_V3DV: return "mesa-v3dv";
	case VK_DRIVER_ID_MESA_PANVK: return "mesa-panvk";
	case VK_DRIVER_ID_SAMSUNG_PROPRIETARY: return "samsung";
	case VK_DRIVER_ID_MESA_VENUS: return "mesa-venus";
	case VK_DRIVER_ID_MESA_DOZEN: return "mesa-dozen";
	case VK_DRIVER_ID_MESA_NVK: return "mesa-nvk";
	case VK_DRIVER_ID_IMAGINATION_OPEN_SOURCE_MESA: return "imagination-mesa";
	case VK_DRIVER_ID_MESA_AGXV: return "mesa-agxv";
	default: return "unknown";
	}
}

static const char *device_type_name(VkPhysicalDeviceType t)
{
	switch (t) {
	case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return "integrated";
	case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: return "discrete";
	case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: return "virtual";
	case VK_PHYSICAL_DEVICE_TYPE_CPU: return "cpu";
	default: return "other";
	}
}

/* 功能测试: 填一块 1MiB 的 buffer 再读回来校验 */
static void buffer_fill_test(VkDevice dev, VkPhysicalDevice pdev,
			     uint32_t family, VkQueue queue)
{
	const VkDeviceSize size = 1024 * 1024;
	VkBufferCreateInfo bci = { 0 };
	VkMemoryRequirements req;
	VkMemoryAllocateInfo mai = { 0 };
	VkCommandPoolCreateInfo pci = { 0 };
	VkCommandBufferAllocateInfo cai = { 0 };
	VkCommandBuffer cmd = VK_NULL_HANDLE;
	VkCommandPool pool = VK_NULL_HANDLE;
	VkDeviceMemory mem = VK_NULL_HANDLE;
	VkBuffer buf = VK_NULL_HANDLE;
	VkFenceCreateInfo fci = { 0 };
	VkFence fence = VK_NULL_HANDLE;
	VkSubmitInfo si = { 0 };
	VkCommandBufferBeginInfo bi = { 0 };
	VkBufferMemoryBarrier bb = { 0 };
	VkPhysicalDeviceMemoryProperties mp;
	VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
				     VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
	const uint32_t pattern = 0x12345678u;
	uint32_t *map = NULL;
	int mem_type = -1;
	int mismatch = -1;
	int i;

	bci.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
	bci.size = size;
	bci.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
	bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
	if (vkCreateBuffer(dev, &bci, NULL, &buf) != VK_SUCCESS) {
		ap("  fill 测试: 创建 buffer 失败\n");
		return;
	}
	vkGetBufferMemoryRequirements(dev, buf, &req);
	vkGetPhysicalDeviceMemoryProperties(pdev, &mp);
	for (i = 0; i < (int)mp.memoryTypeCount; i++) {
		if ((req.memoryTypeBits & (1u << i)) &&
		    (mp.memoryTypes[i].propertyFlags & want) == want) {
			mem_type = i;
			break;
		}
	}
	if (mem_type < 0) {
		ap("  fill 测试: 没有 host 可见内存类型, 跳过\n");
		vkDestroyBuffer(dev, buf, NULL);
		return;
	}
	mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
	mai.allocationSize = req.size;
	mai.memoryTypeIndex = (uint32_t)mem_type;
	if (vkAllocateMemory(dev, &mai, NULL, &mem) != VK_SUCCESS ||
	    vkBindBufferMemory(dev, buf, mem, 0) != VK_SUCCESS) {
		ap("  fill 测试: 分配/绑定内存失败\n");
		goto out;
	}

	pci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
	pci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
	pci.queueFamilyIndex = family;
	if (vkCreateCommandPool(dev, &pci, NULL, &pool) != VK_SUCCESS)
		goto out;
	cai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
	cai.commandPool = pool;
	cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	cai.commandBufferCount = 1;
	if (vkAllocateCommandBuffers(dev, &cai, &cmd) != VK_SUCCESS)
		goto out;

	bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
	bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
	if (vkBeginCommandBuffer(cmd, &bi) != VK_SUCCESS)
		goto out;
	vkCmdFillBuffer(cmd, buf, 0, size, pattern);
	bb.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
	bb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
	bb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
	bb.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
	bb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
	bb.buffer = buf;
	bb.offset = 0;
	bb.size = size;
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
			     0, 0, NULL, 1, &bb, 0, NULL);
	if (vkEndCommandBuffer(cmd) != VK_SUCCESS)
		goto out;

	fci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
	if (vkCreateFence(dev, &fci, NULL, &fence) != VK_SUCCESS)
		goto out;
	si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
	si.commandBufferCount = 1;
	si.pCommandBuffers = &cmd;
	if (vkQueueSubmit(queue, 1, &si, fence) != VK_SUCCESS ||
	    vkWaitForFences(dev, 1, &fence, VK_TRUE, 3000000000ull) != VK_SUCCESS) {
		ap("  fill 测试: 提交/等待失败\n");
		goto out;
	}
	if (vkMapMemory(dev, mem, 0, size, 0, (void **)&map) != VK_SUCCESS) {
		ap("  fill 测试: map 失败\n");
		goto out;
	}
	for (i = 0; i < (int)(size / 4); i++) {
		if (map[i] != pattern) {
			mismatch = i;
			break;
		}
	}
	vkUnmapMemory(dev, mem);
	if (mismatch < 0)
		ap("  fill 1MiB + 回读校验: PASS (pattern 0x%08x)\n", pattern);
	else
		ap("  fill 1MiB + 回读校验: FAIL (第 %d 个字不匹配: 0x%08x)\n",
		   mismatch, map ? map[0] : 0);

out:
	if (fence != VK_NULL_HANDLE)
		vkDestroyFence(dev, fence, NULL);
	if (pool != VK_NULL_HANDLE)
		vkDestroyCommandPool(dev, pool, NULL);
	if (mem != VK_NULL_HANDLE)
		vkFreeMemory(dev, mem, NULL);
	if (buf != VK_NULL_HANDLE)
		vkDestroyBuffer(dev, buf, NULL);
}

/* 渲染测试: 256x256 render pass 清屏 + 普通提交开销, 各跑 200 次 */
static void render_test(VkDevice dev, VkPhysicalDevice pdev,
			uint32_t family, VkQueue queue)
{
	const uint32_t N = 200;
	VkFormat fmt = VK_FORMAT_R8G8B8A8_UNORM;
	VkFormatProperties fp;
	VkImageCreateInfo ici = { 0 };
	VkImageViewCreateInfo vci = { 0 };
	VkRenderPassCreateInfo rpci = { 0 };
	VkFramebufferCreateInfo fbci = { 0 };
	VkCommandPoolCreateInfo pci = { 0 };
	VkCommandBufferAllocateInfo cai = { 0 };
	VkFenceCreateInfo fci = { 0 };
	VkSubmitInfo si = { 0 };
	VkCommandBufferBeginInfo bi = { 0 };
	VkAttachmentDescription att = { 0 };
	VkAttachmentReference ref = { 0 };
	VkSubpassDescription sub = { 0 };
	VkSubpassDependency dep = { 0 };
	VkClearValue clear;
	VkRenderPassBeginInfo rbi = { 0 };
	VkMemoryRequirements req;
	VkMemoryAllocateInfo mai = { 0 };
	VkPhysicalDeviceMemoryProperties mp;
	VkDeviceMemory mem = VK_NULL_HANDLE;
	VkCommandPool pool = VK_NULL_HANDLE;
	VkCommandBuffer cmd = VK_NULL_HANDLE;
	VkFramebuffer fb = VK_NULL_HANDLE;
	VkRenderPass rp = VK_NULL_HANDLE;
	VkImageView view = VK_NULL_HANDLE;
	VkImage img = VK_NULL_HANDLE;
	VkFence fence = VK_NULL_HANDLE;
	int mem_type = -1;
	double t0, t1;
	uint32_t i;

	vkGetPhysicalDeviceFormatProperties(pdev, fmt, &fp);
	if (!(fp.optimalTilingFeatures & VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT)) {
		ap("  render pass 清屏: 设备不支持 %s 颜色附件, 跳过\n", "RGBA8");
		return;
	}

	ici.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
	ici.imageType = VK_IMAGE_TYPE_2D;
	ici.format = fmt;
	ici.extent.width = 256;
	ici.extent.height = 256;
	ici.extent.depth = 1;
	ici.mipLevels = 1;
	ici.arrayLayers = 1;
	ici.samples = VK_SAMPLE_COUNT_1_BIT;
	ici.tiling = VK_IMAGE_TILING_OPTIMAL;
	ici.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
	ici.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
	ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
	if (vkCreateImage(dev, &ici, NULL, &img) != VK_SUCCESS)
		goto out;
	vkGetImageMemoryRequirements(dev, img, &req);
	vkGetPhysicalDeviceMemoryProperties(pdev, &mp);
	for (i = 0; i < mp.memoryTypeCount; i++) {
		if ((req.memoryTypeBits & (1u << i)) &&
		    (mp.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
			mem_type = (int)i;
			break;
		}
	}
	if (mem_type < 0)
		goto out;
	mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
	mai.allocationSize = req.size;
	mai.memoryTypeIndex = (uint32_t)mem_type;
	if (vkAllocateMemory(dev, &mai, NULL, &mem) != VK_SUCCESS ||
	    vkBindImageMemory(dev, img, mem, 0) != VK_SUCCESS)
		goto out;

	att.format = fmt;
	att.samples = VK_SAMPLE_COUNT_1_BIT;
	att.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
	att.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
	att.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
	att.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
	att.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
	att.finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
	ref.attachment = 0;
	ref.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
	sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
	sub.colorAttachmentCount = 1;
	sub.pColorAttachments = &ref;
	dep.srcSubpass = VK_SUBPASS_EXTERNAL;
	dep.dstSubpass = 0;
	dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
	dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
	dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
	rpci.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
	rpci.attachmentCount = 1;
	rpci.pAttachments = &att;
	rpci.subpassCount = 1;
	rpci.pSubpasses = &sub;
	rpci.dependencyCount = 1;
	rpci.pDependencies = &dep;
	if (vkCreateRenderPass(dev, &rpci, NULL, &rp) != VK_SUCCESS)
		goto out;

	vci.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
	vci.image = img;
	vci.viewType = VK_IMAGE_VIEW_TYPE_2D;
	vci.format = fmt;
	vci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
	vci.subresourceRange.levelCount = 1;
	vci.subresourceRange.layerCount = 1;
	if (vkCreateImageView(dev, &vci, NULL, &view) != VK_SUCCESS)
		goto out;
	fbci.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
	fbci.renderPass = rp;
	fbci.attachmentCount = 1;
	fbci.pAttachments = &view;
	fbci.width = 256;
	fbci.height = 256;
	fbci.layers = 1;
	if (vkCreateFramebuffer(dev, &fbci, NULL, &fb) != VK_SUCCESS)
		goto out;

	pci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
	pci.queueFamilyIndex = family;
	if (vkCreateCommandPool(dev, &pci, NULL, &pool) != VK_SUCCESS)
		goto out;
	cai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
	cai.commandPool = pool;
	cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	cai.commandBufferCount = 1;
	if (vkAllocateCommandBuffers(dev, &cai, &cmd) != VK_SUCCESS)
		goto out;
	bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
	if (vkBeginCommandBuffer(cmd, &bi) != VK_SUCCESS)
		goto out;
	memset(&clear, 0, sizeof(clear));
	clear.color.float32[0] = 0.1f;
	clear.color.float32[1] = 0.2f;
	clear.color.float32[2] = 0.3f;
	clear.color.float32[3] = 1.0f;
	rbi.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
	rbi.renderPass = rp;
	rbi.framebuffer = fb;
	rbi.renderArea.extent.width = 256;
	rbi.renderArea.extent.height = 256;
	rbi.clearValueCount = 1;
	rbi.pClearValues = &clear;
	for (i = 0; i < 20; i++) {
		vkCmdBeginRenderPass(cmd, &rbi, VK_SUBPASS_CONTENTS_INLINE);
		vkCmdEndRenderPass(cmd);
	}
	if (vkEndCommandBuffer(cmd) != VK_SUCCESS)
		goto out;
	fci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
	if (vkCreateFence(dev, &fci, NULL, &fence) != VK_SUCCESS)
		goto out;
	si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
	si.commandBufferCount = 1;
	si.pCommandBuffers = &cmd;

	t0 = now_ms();
	for (i = 0; i < N; i++) {
		vkResetFences(dev, 1, &fence);
		if (vkQueueSubmit(queue, 1, &si, fence) != VK_SUCCESS ||
		    vkWaitForFences(dev, 1, &fence, VK_TRUE, 3000000000ull) != VK_SUCCESS)
			break;
	}
	t1 = now_ms();
	if (i == N)
		ap("  render pass 清屏 256x256 x20 x%u 次: %.2f ms/次 (共 %.0f ms)\n",
		   N, (t1 - t0) / N, t1 - t0);
	else
		ap("  render pass 清屏: 第 %u 次提交失败\n", i);

out:
	if (fence != VK_NULL_HANDLE)
		vkDestroyFence(dev, fence, NULL);
	if (pool != VK_NULL_HANDLE)
		vkDestroyCommandPool(dev, pool, NULL);
	if (fb != VK_NULL_HANDLE)
		vkDestroyFramebuffer(dev, fb, NULL);
	if (view != VK_NULL_HANDLE)
		vkDestroyImageView(dev, view, NULL);
	if (rp != VK_NULL_HANDLE)
		vkDestroyRenderPass(dev, rp, NULL);
	if (mem != VK_NULL_HANDLE)
		vkFreeMemory(dev, mem, NULL);
	if (img != VK_NULL_HANDLE)
		vkDestroyImage(dev, img, NULL);
}

static void probe_device(VkPhysicalDevice pdev, uint32_t index)
{
	VkPhysicalDeviceProperties p;
	VkPhysicalDeviceFeatures f;
	VkPhysicalDeviceMemoryProperties mp;
	uint32_t ext_count = 0, qf_count = 0;
	uint32_t family = UINT32_MAX;
	VkQueueFamilyProperties *qfs = NULL;
	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = { 0 };
	VkDeviceCreateInfo dci = { 0 };
	VkDevice dev = VK_NULL_HANDLE;
	VkQueue queue = VK_NULL_HANDLE;
	uint32_t i;

	vkGetPhysicalDeviceProperties(pdev, &p);
	ap("物理设备 %u: %s\n", index, p.deviceName);
	ap("  类型: %s | vendorID=0x%04x deviceID=0x%04x\n",
	   device_type_name(p.deviceType), p.vendorID, p.deviceID);
	ap("  apiVersion: %u.%u.%u | driverVersion: 0x%08x (%u.%u.%u)\n",
	   VK_VERSION_MAJOR(p.apiVersion), VK_VERSION_MINOR(p.apiVersion),
	   VK_VERSION_PATCH(p.apiVersion), p.driverVersion,
	   VK_VERSION_MAJOR(p.driverVersion), VK_VERSION_MINOR(p.driverVersion),
	   VK_VERSION_PATCH(p.driverVersion));
	/* 注意: driverID/driverName 要 Vulkan 1.1 的 vkGetPhysicalDeviceProperties2,
	 * NDK 的 libvulkan 桩在 API 26 上只有 1.0 符号, 所以这里只用 1.0 接口;
	 * 驱动身份由 EnvProbe 读取进程实际加载的 .so 判断。 */
	ap("  limits: maxImage2D=%u maxComputeWGInvocations=%u maxVertexOutput=%u\n",
	   p.limits.maxImageDimension2D, p.limits.maxComputeWorkGroupInvocations,
	   p.limits.maxVertexOutputComponents);

	if (vkEnumerateDeviceExtensionProperties(pdev, NULL, &ext_count, NULL) == VK_SUCCESS)
		ap("  设备扩展数量: %u\n", ext_count);

	vkGetPhysicalDeviceMemoryProperties(pdev, &mp);
	ap("  内存堆 %u 个:", mp.memoryHeapCount);
	for (i = 0; i < mp.memoryHeapCount; i++)
		ap(" [%u] %.0f MiB%s", i, (double)mp.memoryHeaps[i].size / 1048576.0,
		   (mp.memoryHeaps[i].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) ? " local" : "");
	ap("\n");

	vkGetPhysicalDeviceQueueFamilyProperties(pdev, &qf_count, NULL);
	qfs = (VkQueueFamilyProperties *)calloc(qf_count ? qf_count : 1, sizeof(*qfs));
	if (qfs) {
		vkGetPhysicalDeviceQueueFamilyProperties(pdev, &qf_count, qfs);
		ap("  队列族 %u 个:", qf_count);
		for (i = 0; i < qf_count; i++) {
			ap(" [%u] n=%u%s%s%s", i, qfs[i].queueCount,
			   (qfs[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) ? " gfx" : "",
			   (qfs[i].queueFlags & VK_QUEUE_COMPUTE_BIT) ? " compute" : "",
			   (qfs[i].queueFlags & VK_QUEUE_TRANSFER_BIT) ? " transfer" : "");
			if (family == UINT32_MAX && (qfs[i].queueFlags & VK_QUEUE_GRAPHICS_BIT))
				family = i;
		}
		ap("\n");
	}

	vkGetPhysicalDeviceFeatures(pdev, &f);
	ap("  功能: geometryShader=%d tessellation=%d compute=%d depthClamp=%d\n",
	   f.geometryShader, f.tessellationShader, f.shaderStorageImageWriteWithoutFormat,
	   f.depthClamp);

	if (family == UINT32_MAX) {
		ap("  没有图形队列族, 跳过功能/渲染测试\n\n");
		free(qfs);
		return;
	}

	qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
	qci.queueFamilyIndex = family;
	qci.queueCount = 1;
	qci.pQueuePriorities = &prio;
	dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
	dci.queueCreateInfoCount = 1;
	dci.pQueueCreateInfos = &qci;
	if (vkCreateDevice(pdev, &dci, NULL, &dev) != VK_SUCCESS) {
		ap("  vkCreateDevice 失败, 跳过功能/渲染测试\n\n");
		free(qfs);
		return;
	}
	vkGetDeviceQueue(dev, family, 0, &queue);

	buffer_fill_test(dev, pdev, family, queue);
	render_test(dev, pdev, family, queue);

	/* 提交空 command buffer 的固定开销, 用来解释渲染测试的数字 */
	{
		VkCommandPoolCreateInfo cpci = { 0 };
		VkCommandPool cp = VK_NULL_HANDLE;
		VkCommandBufferAllocateInfo cbai = { 0 };
		VkCommandBuffer cbuf = VK_NULL_HANDLE;
		VkFenceCreateInfo fci2 = { 0 };
		VkFence f2 = VK_NULL_HANDLE;
		VkSubmitInfo si2 = { 0 };
		VkCommandBufferBeginInfo bi2 = { 0 };
		double a, b;
		uint32_t k;

		cpci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
		cpci.queueFamilyIndex = family;
		if (vkCreateCommandPool(dev, &cpci, NULL, &cp) == VK_SUCCESS) {
			cbai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
			cbai.commandPool = cp;
			cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
			cbai.commandBufferCount = 1;
			if (vkAllocateCommandBuffers(dev, &cbai, &cbuf) == VK_SUCCESS) {
				bi2.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
				vkBeginCommandBuffer(cbuf, &bi2);
				vkEndCommandBuffer(cbuf);
				fci2.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
				if (vkCreateFence(dev, &fci2, NULL, &f2) == VK_SUCCESS) {
					si2.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
					si2.commandBufferCount = 1;
					si2.pCommandBuffers = &cbuf;
					a = now_ms();
					for (k = 0; k < 200; k++) {
						vkResetFences(dev, 1, &f2);
						if (vkQueueSubmit(queue, 1, &si2, f2) != VK_SUCCESS ||
						    vkWaitForFences(dev, 1, &f2, VK_TRUE, 3000000000ull) != VK_SUCCESS)
							break;
					}
					b = now_ms();
					if (k == 200)
						ap("  空提交 x200: %.3f ms/次\n", (b - a) / 200.0);
					vkDestroyFence(dev, f2, NULL);
				}
			}
			vkDestroyCommandPool(dev, cp, NULL);
		}
	}

	ap("\n");
	vkDestroyDevice(dev, NULL);
	free(qfs);
}

JNIEXPORT jstring JNICALL
Java_com_zren_panvkprobe_ProbeNative_vulkanReport(JNIEnv *env, jclass clazz)
{
	VkApplicationInfo ai = { 0 };
	VkInstanceCreateInfo ci = { 0 };
	VkInstance inst = VK_NULL_HANDLE;
	VkPhysicalDevice *devs = NULL;
	uint32_t count = 0, ext_count = 0;
	VkResult res;
	uint32_t i;

	(void)clazz;
	g_off = 0;
	g_report[0] = '\0';

	res = vkEnumerateInstanceExtensionProperties(NULL, &ext_count, NULL);
	ap("Vulkan loader 实例扩展数量: %u%s\n",
	   (res == VK_SUCCESS) ? ext_count : 0,
	   (res == VK_SUCCESS) ? "" : " (枚举失败)");

	ai.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
	ai.pApplicationName = "PanVK Probe";
	ai.applicationVersion = 1;
	ai.pEngineName = "none";
	ai.apiVersion = VK_API_VERSION_1_0;
	ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
	ci.pApplicationInfo = &ai;
	res = vkCreateInstance(&ci, NULL, &inst);
	if (res != VK_SUCCESS) {
		ap("vkCreateInstance 失败: %d (没有可用驱动?)\n", res);
		return (*env)->NewStringUTF(env, g_report);
	}

	res = vkEnumeratePhysicalDevices(inst, &count, NULL);
	if (res != VK_SUCCESS || count == 0) {
		ap("没有枚举到物理设备 (VkResult=%d)\n", res);
		ap("说明: loader 起来了但没有任何驱动被加载。常见原因是替换上去的 so\n");
		ap("      不是标准 HAL (缺 HAL_MODULE_INFO_SYM) 也不是 ICD\n");
		ap("      (缺 vk_icdGetInstanceProcAddr), 例如只导出 HMI 的 Winlator 版驱动。\n");
		vkDestroyInstance(inst, NULL);
		return (*env)->NewStringUTF(env, g_report);
	}
	ap("物理设备数量: %u\n", count);
	devs = (VkPhysicalDevice *)calloc(count, sizeof(*devs));
	if (devs) {
		res = vkEnumeratePhysicalDevices(inst, &count, devs);
		if (res == VK_SUCCESS) {
			for (i = 0; i < count; i++)
				probe_device(devs[i], i);
		}
		free(devs);
	}

	vkDestroyInstance(inst, NULL);
	return (*env)->NewStringUTF(env, g_report);
}

/*
 * 直接按 libhardware 的方式加载 HAL 模块并逐项报告, 用来定位"替换后没有设备"卡在哪:
 *   dlopen -> dlsym("HMI") -> tag/id 检查 -> methods->open("vulkan") -> getInstanceProcAddr
 * (AOSP 里 #define HAL_MODULE_INFO_SYM HMI, libhardware 找的符号就是 "HMI")
 */
typedef struct {
	uint32_t tag;
	uint16_t module_api_version;
	uint16_t hal_api_version;
	const char *id;
	const char *name;
	const char *author;
	void *methods;
	void *dso;
	uint64_t reserved[32 - 7];
} probe_hw_module_t;

typedef struct {
	uint32_t tag;
	uint16_t module_api_version;
	uint16_t hal_api_version;
	const char *id;
	const char *name;
	const char *author;
	const void *module;

	uint64_t reserved[12];
} probe_hw_device_t;

typedef int (*probe_open_t)(const probe_hw_module_t *, const char *, probe_hw_device_t **);
typedef void *(*probe_get_proc_t)(const void *, const char *);

#define HW_MODULE_TAG 0x48574d54u /* MAKE_TAG_CONSTANT('H','W','M','T') */

static void hal_probe_one(const char *path)
{
	void *handle;
	probe_hw_module_t *mod;
	probe_hw_device_t *dev = NULL;
	probe_open_t open_fn;
	const char *err;
	int rc;

	ap("路径: %s\n", path);
	handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!handle) {
		ap("  dlopen 失败: %s\n", dlerror());
		return;
	}
	ap("  dlopen OK\n");

	dlerror();
	mod = (probe_hw_module_t *)dlsym(handle, "HMI");
	if (!mod)
		mod = (probe_hw_module_t *)dlsym(handle, "HAL_MODULE_INFO_SYM");
	err = dlerror();
	if (!mod) {
		ap("  找不到 HMI 符号: %s\n", err ? err : "?");
		return;
	}
	ap("  HMI: tag=0x%08x (期望 0x%08x) api=%u/%u\n",
	   mod->tag, HW_MODULE_TAG, mod->module_api_version, mod->hal_api_version);
	ap("       id=%s name=%s author=%s methods=%p\n",
	   mod->id ? mod->id : "?", mod->name ? mod->name : "?",
	   mod->author ? mod->author : "?", mod->methods);
	if (mod->tag != HW_MODULE_TAG)
		ap("  !! tag 不是标准 HAL tag, libhardware 会拒绝\n");
	if (strcmp(mod->id ? mod->id : "", "vulkan") != 0)
		ap("  !! id 不是 \"vulkan\"\n");
	if (!mod->methods) {
		ap("  没有 methods, 无法 open\n");
		return;
	}

	open_fn = (probe_open_t)((void **)mod->methods)[0];
	ap("  methods->open=%p\n", (void *)open_fn);
	if (!open_fn) {
		ap("  open 为空\n");
		return;
	}
	rc = open_fn(mod, "vulkan", &dev);
	ap("  open(\"vulkan\") = %d%s\n", rc, rc < 0 ? " (失败)" : "");
	if (rc != 0 || !dev) {
		ap("  结论: 驱动本体加载/初始化失败, 这一步失败就会导致 Vulkan 一个设备都没有\n");
		return;
	}

	/* hwvulkan_device_t: common 之后紧跟 getInstanceProcAddr */
	{
		void *gipa = NULL;
		probe_get_proc_t get_instance_proc = NULL;
		size_t off;

		/* 兼容两种布局: 直接跟在 common 后面 */
		for (off = sizeof(probe_hw_device_t); off <= sizeof(probe_hw_device_t) + 16; off += 8) {
			memcpy(&gipa, (const char *)dev + off, sizeof(gipa));
			if (gipa) {
				get_instance_proc = (probe_get_proc_t)gipa;
				break;
			}
		}
		ap("  getInstanceProcAddr=%p\n", gipa);
		if (get_instance_proc) {
			void *p = get_instance_proc(NULL, "vkEnumeratePhysicalDevices");
			ap("  getInstanceProcAddr(\"vkEnumeratePhysicalDevices\")=%p%s\n",
			   p, p ? " (可以枚举设备)" : " (拿不到, 驱动内部有问题)");
		}
	}
}

JNIEXPORT jstring JNICALL
Java_com_zren_panvkprobe_ProbeNative_halReport(JNIEnv *env, jclass clazz)
{
	static const char *paths[] = {
		"/vendor/lib64/hw/vulkan.mali.so",
		"/vendor/lib64/hw/vulkan.adreno.so",
		"/system/lib64/libvulkan_panvk.so",
		"/vendor/lib64/hw/vulkan.kmgsl.so",
	};
	uint32_t i;
	char real[512];

	(void)clazz;
	g_off = 0;
	g_report[0] = '\0';

	ap("按 libhardware 的方式直接加载 HAL 模块 (替换后没设备时看这里)\n\n");
	for (i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
		const char *p = paths[i];
		const char *rp = realpath(p, real);

		if (!rp) {
			ap("路径: %s -> 不存在\n\n", p);
			continue;
		}
		if (strcmp(rp, p) != 0)
			ap("(符号链接 -> %s)\n", rp);
		hal_probe_one(p);
		ap("\n");
	}
	return (*env)->NewStringUTF(env, g_report);
}
