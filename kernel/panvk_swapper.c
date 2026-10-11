// SPDX-License-Identifier: GPL-2.0
/*
 * panvk_swapper - 按进程 (UID) 替换用户层图形驱动为 PanVK 开源驱动
 *
 * 目标:
 *   只让 WebUI 勾选的那些应用 (按 UID 识别) 在加载 Vulkan 驱动时使用
 *   开源 PanVK (Mesa panfrost) ICD, 设备上其它进程完全不受影响。
 *
 * 原理:
 *   Android 的 Vulkan loader 在 *应用自己的进程里* 打开厂商 ICD 描述文件,
 *   例如 /vendor/etc/vulkan/icd.d/mali.json。本模块在 do_filp_open() 上挂一个
 *   kprobe, 当
 *     - 总开关 enabled=1, 且
 *     - 当前进程 UID 命中目标集合, 且
 *     - 待打开的路径名命中某条 rules 规则
 *   时, 就地改写 struct filename->name 字符串, 把路径换成模块自带的
 *   panvk ICD (默认 /system/etc/panvk/icd.d/panvk.json)。
 *
 *   改写发生在 do_filp_open() 真正执行之前: do_filp_open() 会调用
 *   set_nameidata()/path_init(), 而 path_init() 读取的正是 ->name, 所以随后的
 *   路径解析 (以及 DAC/SELinux 检查) 都是针对替换后的文件、使用调用进程自己的
 *   凭证完成的。别的进程打开同一个 json 依然拿到厂商驱动。
 *
 *   为什么是"就地改写字符串"而不是"替换指针":
 *     struct filename->name 指向 names_cache 里一块 PATH_MAX 大小的缓冲区
 *     (短路径时就是内嵌的 iname)。putname() 会对 name->name != name->iname 的
 *     情况调用 __putname(name->name), 那是按 names_cachep 的对象大小释放的。
 *     如果我们换成一个 kmalloc 的指针, 释放时就是错误的瘦身, 直接破坏 slab。
 *     就地覆写不改变任何指针, 不产生新的生命周期问题, 也不需要 kretprobe
 *     去恢复现场, 因此只要一个最普通的 kprobe 就够了。
 *
 * 参数 (WebUI 通过 control.sh 写入):
 *   enabled    总开关                (0/1, 默认 0)
 *   uids       目标 UID 列表          ("10123,10500", 默认空)
 *   rules      重定向规则             ("src|dst;src|dst", src 以 * 结尾表示前缀匹配)
 *   available  探针是否注册成功       (只读)
 *   redirects  已生效的重定向次数     (只读)
 *
 * 限制:
 *   - 仅 arm64 + CONFIG_KPROBES + CONFIG_KRETPROBES
 *   - 依赖 kallsyms 里存在 do_filp_open (被内联/被 LTO 内部化时会注册失败,
 *     此时 available=0, 内核日志会说明原因, 功能整体静默不生效)
 *   - 只处理"打开文件"这条路径, 已经打开的 fd 不会被动过
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/string.h>
#include <linux/atomic.h>
#include <linux/cred.h>
#include <linux/uidgid.h>
#include <linux/mm.h>
#include <linux/fs.h>

#include "panvk_parse.h"

#define PS_STR_MAX   1024

/* 兜底替换目标; 正常运行时 control.sh 会下发按载荷生成的完整规则 */
#define PS_PANVK_ICD "/system/etc/panvk/icd.d/panvk.json"

/* 规则表只在 ps_rules_lock 保护下替换/释放, 读者持同一把锁 */
static struct ps_table *ps_rules;
static DEFINE_SPINLOCK(ps_rules_lock);

/* 目标 UID 集合 */
static unsigned int ps_uids[PS_MAX_UIDS];
static unsigned int ps_uid_count;
static unsigned int ps_uid_min;
static unsigned int ps_uid_max;
static DEFINE_SPINLOCK(ps_uids_lock);

static bool ps_enabled;
static atomic64_t ps_redirects = ATOMIC64_INIT(0);
static bool ps_probe_ok;
static int ps_available;

static char ps_uids_str[PS_STR_MAX];
static char ps_rules_str[PS_STR_MAX];

/* ------------------------------------------------------------------ */
/* 规则表                                                              */
/* ------------------------------------------------------------------ */

static int ps_parse_rules(const char *val)
{
	struct ps_table *t;
	unsigned long flags;

	t = kzalloc(sizeof(*t), GFP_KERNEL);
	if (!t)
		return -ENOMEM;

	ps_rules_parse(val, t);

	spin_lock_irqsave(&ps_rules_lock, flags);
	{
		struct ps_table *old = ps_rules;

		ps_rules = t;
		spin_unlock_irqrestore(&ps_rules_lock, flags);
		kfree(old);
	}

	pr_info("规则表已更新: %u 条\n", t->nr);
	return 0;
}

/* ------------------------------------------------------------------ */
/* UID 集合                                                            */
/* ------------------------------------------------------------------ */

static int ps_parse_uids(const char *val)
{
	unsigned int tmp[PS_MAX_UIDS];
	unsigned int nr, min = 0, max = 0;
	unsigned long flags;

	nr = ps_uids_parse(val, tmp, &min, &max);

	spin_lock_irqsave(&ps_uids_lock, flags);
	memcpy(ps_uids, tmp, nr * sizeof(tmp[0]));
	ps_uid_count = nr;
	ps_uid_min = min;
	ps_uid_max = max;
	spin_unlock_irqrestore(&ps_uids_lock, flags);

	pr_info("目标 UID 已更新: %u 个\n", nr);
	return 0;
}

static bool ps_uid_is_target(unsigned int uid)
{
	unsigned long flags;
	unsigned int i;
	bool found = false;

	if (uid < ps_uid_min || uid > ps_uid_max)
		return false;

	spin_lock_irqsave(&ps_uids_lock, flags);
	for (i = 0; i < ps_uid_count; i++) {
		if (ps_uids[i] == uid) {
			found = true;
			break;
		}
	}
	spin_unlock_irqrestore(&ps_uids_lock, flags);
	return found;
}

/* ------------------------------------------------------------------ */
/* kprobe                                                              */
/* ------------------------------------------------------------------ */

/*
 * 返回非 0 表示已改写。调用时持 ps_rules_lock, 只在命中时 kmalloc。
 * 这里只做字符串比较和一次 memcpy, 全部在 atomic 上下文里安全。
 */
static bool ps_rewrite_name(struct filename *path)
{
	struct ps_table *t;
	unsigned long flags;
	unsigned int i;
	bool done = false;

	spin_lock_irqsave(&ps_rules_lock, flags);
	t = ps_rules;
	if (t) {
		for (i = 0; i < t->nr; i++) {
			const struct ps_rule *r = &t->rules[i];
			bool hit = r->prefix
				? !strncmp(path->name, r->src, r->srclen)
				: !strcmp(path->name, r->src);

			if (!hit)
				continue;

			/*
			 * 就地覆写: 目标缓冲区由 names_cache 提供, 至少
			 * EMBEDDED_NAME_MAX (约 4KB) 字节可写, 规则的
			 * dst 已被限制在 PS_NAME_MAX 以内, 所以安全。
			 */
			memcpy((char *)path->name, r->dst, r->dstlen + 1);
			atomic64_inc(&ps_redirects);
			pr_debug("重定向 uid=%u '%s' -> '%s'\n",
				 __kuid_val(current_uid()), r->src, r->dst);
			done = true;
			break;
		}
	}
	spin_unlock_irqrestore(&ps_rules_lock, flags);
	return done;
}

/*
 * do_filp_open(int dfd, struct filename *pathname, const struct open_flags *op)
 * arm64 上第 2 个参数在 x1。
 */
static int ps_pre_handler(struct kprobe *kp, struct pt_regs *regs)
{
	struct filename *path;
	unsigned int uid;

	if (!READ_ONCE(ps_enabled))
		return 0;

	uid = __kuid_val(current_uid());
	if (!ps_uid_count)
		return 0;
	if (!ps_uid_is_target(uid))
		return 0;

	path = (struct filename *)regs->regs[1];
	if (!path || !path->name || !path->name[0])
		return 0;

	ps_rewrite_name(path);
	return 0;
}

static struct kprobe ps_kp = {
	.symbol_name = "do_filp_open",
	.pre_handler = ps_pre_handler,
};

/* ------------------------------------------------------------------ */
/* 模块参数                                                            */
/* ------------------------------------------------------------------ */

static int ps_set_bool(const char *val, const struct kernel_param *kp)
{
	bool want;

	if (!ps_parse_bool(val, &want))
		return -EINVAL;

	WRITE_ONCE(ps_enabled, want);
	pr_info("总开关: %s\n", want ? "启用" : "停用");
	return 0;
}

static const struct kernel_param_ops ps_bool_ops = {
	.set = ps_set_bool,
	.get = param_get_bool,
};

static int ps_set_uids(const char *val, const struct kernel_param *kp)
{
	int ret;

	ret = param_set_copystring(val, kp);
	if (ret)
		return ret;
	ps_str_strip(ps_uids_str);
	return ps_parse_uids(ps_uids_str);
}

static const struct kernel_param_ops ps_uids_ops = {
	.set = ps_set_uids,
	.get = param_get_string,
};

static struct kparam_string ps_uids_kstr = {
	.maxlen = sizeof(ps_uids_str),
	.string = ps_uids_str,
};

static int ps_set_rules(const char *val, const struct kernel_param *kp)
{
	int ret;

	ret = param_set_copystring(val, kp);
	if (ret)
		return ret;
	ps_str_strip(ps_rules_str);
	return ps_parse_rules(ps_rules_str);
}

static const struct kernel_param_ops ps_rules_ops = {
	.set = ps_set_rules,
	.get = param_get_string,
};

static struct kparam_string ps_rules_kstr = {
	.maxlen = sizeof(ps_rules_str),
	.string = ps_rules_str,
};

static int ps_get_redirects(char *buf, const struct kernel_param *kp)
{
	return scnprintf(buf, PAGE_SIZE, "%llu\n",
			 (unsigned long long)atomic64_read(&ps_redirects));
}

static const struct kernel_param_ops ps_redirects_ops = {
	.get = ps_get_redirects,
};

module_param_cb(enabled, &ps_bool_ops, &ps_enabled, 0644);
MODULE_PARM_DESC(enabled, "总开关: 1 启用按 UID 的驱动替换, 0 停用");

module_param_cb(uids, &ps_uids_ops, &ps_uids_kstr, 0644);
MODULE_PARM_DESC(uids, "目标 UID 列表, 逗号分隔, 例如 10123,10500");

module_param_cb(rules, &ps_rules_ops, &ps_rules_kstr, 0644);
MODULE_PARM_DESC(rules, "重定向规则 src|dst;... src 以 * 结尾表示前缀匹配");

module_param_cb(redirects, &ps_redirects_ops, NULL, 0444);
MODULE_PARM_DESC(redirects, "已生效的重定向次数");

module_param_named(available, ps_available, int, 0444);
MODULE_PARM_DESC(available, "do_filp_open 探针是否注册成功");

/* ------------------------------------------------------------------ */
/* init / exit                                                         */
/* ------------------------------------------------------------------ */

static const char ps_default_rules[] =
	"/vendor/etc/vulkan/icd.d/*|" PS_PANVK_ICD ";"
	"/system/etc/vulkan/icd.d/*|" PS_PANVK_ICD ";"
	"/odm/etc/vulkan/icd.d/*|" PS_PANVK_ICD;

static int __init ps_init(void)
{
	int ret;

	BUILD_BUG_ON(sizeof(ps_default_rules) > PS_STR_MAX);

	/* 没有通过 insmod 参数 / 内部默认值给过规则时, 用内置默认规则 */
	if (!ps_rules) {
		strscpy(ps_rules_str, ps_default_rules, sizeof(ps_rules_str));
		ret = ps_parse_rules(ps_rules_str);
		if (ret)
			return ret;
	}

	ps_available = 0;
	ret = register_kprobe(&ps_kp);
	if (ret) {
		pr_err("do_filp_open 探针注册失败 (%d), 常见原因是该符号被内联或 KMI 变更\n",
		       ret);
		return 0;   /* 模块仍加载, 让 WebUI 能看到 available=0 */
	}

	ps_probe_ok = true;
	ps_available = 1;
	pr_info("已挂载 do_filp_open 探针, 默认替换目标: " PS_PANVK_ICD "\n");
	return 0;
}

static void __exit ps_exit(void)
{
	if (ps_probe_ok) {
		unregister_kprobe(&ps_kp);
		ps_probe_ok = false;
	}
	kfree(ps_rules);
	ps_rules = NULL;
	pr_info("已卸载, 累计重定向 %llu 次\n",
		(unsigned long long)atomic64_read(&ps_redirects));
}

module_init(ps_init);
module_exit(ps_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("ZRen277353");
MODULE_DESCRIPTION("按 UID 把用户层图形驱动替换为 PanVK 开源驱动");
MODULE_VERSION("0.1.1");
