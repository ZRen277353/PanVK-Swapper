"use strict";

const CANDIDATE_DIRS = [
	"/data/adb/modules/panvk_swapper",
	"/data/adb/modules_update/panvk_swapper",
];

const api = { ready: false, threeArgs: true };
let MODDIR = CANDIDATE_DIRS[0];

const state = {
	status: {},
	apps: [],
	selected: new Set(),
	saved: new Set(),
	busy: false,
	filterSystem: false,
	hasAppInfo: true,
};

const els = {
	statePill: document.getElementById("statePill"),
	toggleBtn: document.getElementById("toggleBtn"),
	masterHint: document.getElementById("masterHint"),
	noticePanel: document.getElementById("noticePanel"),
	noticeText: document.getElementById("noticeText"),
	autoStartSwitch: document.getElementById("autoStartSwitch"),
	autoStartHint: document.getElementById("autoStartHint"),
	searchInput: document.getElementById("searchInput"),
	sysToggle: document.getElementById("sysToggle"),
	appList: document.getElementById("appList"),
	selCount: document.getElementById("selCount"),
	listHint: document.getElementById("listHint"),
	saveBtn: document.getElementById("saveBtn"),
	refreshLogsBtn: document.getElementById("refreshLogsBtn"),
	logBox: document.getElementById("logBox"),
	toast: document.getElementById("toast"),
};

/* ------------------------------------------------------------------ */
/* KernelSU WebUI 桥                                                   */
/* ------------------------------------------------------------------ */

function ksuExec(command, useThreeArgs) {
	return new Promise((resolve, reject) => {
		if (!window.ksu || typeof window.ksu.exec !== "function") {
			reject(new Error("当前管理器没有提供 KernelSU WebUI 接口"));
			return;
		}
		const callback = `panvk_cb_${Date.now()}_${Math.random().toString(16).slice(2)}`;
		window[callback] = (errno, stdout, stderr) => {
			delete window[callback];
			resolve({ errno, stdout: stdout || "", stderr: stderr || "" });
		};
		try {
			if (useThreeArgs) {
				window.ksu.exec(command, "{}", callback);
			} else {
				window.ksu.exec(command, callback);
			}
		} catch (error) {
			delete window[callback];
			reject(error);
		}
	});
}

function probeApi(useThreeArgs) {
	return new Promise((resolve) => {
		let settled = false;
		const timer = window.setTimeout(() => {
			if (!settled) {
				settled = true;
				resolve(false);
			}
		}, 900);
		ksuExec("echo panvk-probe", useThreeArgs).then((result) => {
			if (settled) {
				return;
			}
			settled = true;
			window.clearTimeout(timer);
			resolve(result.stdout.indexOf("panvk-probe") !== -1);
		}).catch(() => {
			if (settled) {
				return;
			}
			settled = true;
			window.clearTimeout(timer);
			resolve(false);
		});
	});
}

async function detectApi() {
	if (!window.ksu || typeof window.ksu.exec !== "function") {
		throw new Error("当前管理器没有提供 KernelSU WebUI 接口");
	}
	api.threeArgs = true;
	if (!(await probeApi(true))) {
		api.threeArgs = false;
		if (!(await probeApi(false))) {
			throw new Error("无法与 KernelSU WebUI 接口通信");
		}
	}
	api.ready = true;
}

async function execShell(command) {
	if (!api.ready) {
		await detectApi();
	}
	return ksuExec(command, api.threeArgs);
}

async function run(action) {
	const result = await execShell(`sh ${MODDIR}/control.sh ${action}`);
	if (result.errno !== 0) {
		const message = (result.stderr || result.stdout || "命令执行失败").trim();
		throw new Error(message);
	}
	return result;
}

/* ------------------------------------------------------------------ */
/* 通用 UI                                                             */
/* ------------------------------------------------------------------ */

function parseKV(output) {
	const data = {};
	for (const line of output.split(/\r?\n/)) {
		const index = line.indexOf("=");
		if (index > 0) {
			data[line.slice(0, index)] = line.slice(index + 1);
		}
	}
	return data;
}

function showToast(message, isError = false) {
	els.toast.textContent = message;
	els.toast.classList.toggle("error", isError);
	els.toast.classList.add("show");
	window.clearTimeout(showToast.timer);
	showToast.timer = window.setTimeout(() => {
		els.toast.classList.remove("show");
	}, isError ? 4200 : 2200);
}

function setBusy(isBusy) {
	state.busy = isBusy;
	els.toggleBtn.disabled = isBusy;
	els.autoStartSwitch.disabled = isBusy;
	els.refreshLogsBtn.disabled = isBusy;
	els.saveBtn.disabled = isBusy || !isDirty();
}

function isDirty() {
	if (state.selected.size !== state.saved.size) {
		return true;
	}
	for (const name of state.selected) {
		if (!state.saved.has(name)) {
			return true;
		}
	}
	return false;
}

/* ------------------------------------------------------------------ */
/* 状态                                                                */
/* ------------------------------------------------------------------ */

function applyStatus(data) {
	state.status = data;

	const enabled = data.enabled === "1";
	const loaded = data.loaded === "1";
	const available = data.available === "1";
	const payloadPresent = data.payload_present === "1";
	const count = data.count || "0";
	const redirects = data.redirects || "0";
	const gpu = data.gpu || "未识别";
	const payload = data.payload || "无";

	els.statePill.classList.remove("on", "off", "warn");
	if (enabled && loaded && available) {
		els.statePill.textContent = "运行中";
		els.statePill.classList.add("on");
	} else if (enabled && !loaded) {
		els.statePill.textContent = "未加载";
		els.statePill.classList.add("warn");
	} else {
		els.statePill.textContent = "已停用";
		els.statePill.classList.add("off");
	}

	els.toggleBtn.textContent = enabled && loaded ? "停用" : "启用";

	if (enabled && loaded && available) {
		els.masterHint.textContent = count === "0"
			? "已启用, 但还没有勾选任何应用"
			: `运行中: ${count} 个应用, 已重定向 ${redirects} 次`;
	} else if (enabled) {
		els.masterHint.textContent = `已启用但内核模块未加载, 请检查日志`;
	} else if (count !== "0") {
		els.masterHint.textContent = `未启用, 已保存 ${count} 个应用的选择`;
	} else {
		els.masterHint.textContent = "未启用, 还没有勾选应用";
	}

	/* 驱动与探针状态 */
	const notices = [];
	let warn = false;
	if (loaded && !available) {
		notices.push("内核探针没有注册成功 (do_filp_open 不可用), 替换不会生效, 详见运行日志。");
		warn = true;
	}
	if (data.pending_reboot === "1") {
		notices.push("刚导入的驱动要重启一次才会挂进 /system, 重启后再启用。");
		warn = true;
	}
	if (!payloadPresent) {
		notices.push("模块里没有 PanVK 驱动, 先用 import-driver.sh 导入一个 .so 再启用。");
		warn = true;
	} else if (!warn) {
		const shape = data.payload_shape === "hal" ? "HAL"
			: data.payload_shape === "icd" ? "ICD" : "未知形态";
		notices.push(`GPU ${gpu}, 当前载荷 ${payload} (${shape}, 共 ${data.payloads || "0"} 个)。`);
	}
	els.noticePanel.hidden = false;
	els.noticePanel.classList.toggle("ok", !warn);
	els.noticeText.textContent = notices.join(" ");

	els.autoStartSwitch.checked = data.auto_start === "1";
	els.autoStartHint.textContent = data.auto_start === "1" ? "开启" : "关闭";
}

function applySelectionFromStatus() {
	state.saved = new Set((state.status.packages || "").split(",").filter(Boolean));
	state.selected = new Set(state.saved);
	syncRows();
	updateSelectionUi();
}

async function refreshStatus() {
	const result = await run("status");
	applyStatus(parseKV(result.stdout));
}

async function refreshLogs() {
	const result = await run("logs");
	els.logBox.textContent = result.stdout.trim() || "(暂无日志)";
	els.logBox.scrollTop = els.logBox.scrollHeight;
}

/* ------------------------------------------------------------------ */
/* 应用列表                                                            */
/* ------------------------------------------------------------------ */

async function loadApps() {
	state.hasAppInfo = hasPackageApi();
	state.apps = [];

	let count = 0;
	if (state.hasAppInfo) {
		try {
			count = await loadAppsFromApi();
		} catch (error) {
			count = 0;
		}
	}
	if (!count) {
		state.hasAppInfo = false;
		count = await loadAppsFromShell();
	}

	state.apps.sort((a, b) =>
		a.label.localeCompare(b.label, "zh-Hans") || a.name.localeCompare(b.name));
	renderApps();
}

/* 新版 KernelSU WebUI 提供 listPackages/getPackagesInfo, 能拿到软件名、系统标记和 uid */
function hasPackageApi() {
	return !!(window.ksu
		&& typeof window.ksu.listPackages === "function"
		&& typeof window.ksu.getPackagesInfo === "function");
}

async function loadAppsFromApi() {
	const names = window.ksu.listPackages("all") || [];
	if (!names.length) {
		return 0;
	}

	const apps = [];
	const chunk = 200;
	for (let i = 0; i < names.length; i += chunk) {
		const infos = window.ksu.getPackagesInfo(names.slice(i, i + chunk)) || [];
		for (const info of infos) {
			if (!info || !info.packageName) {
				continue;
			}
			apps.push({
				name: info.packageName,
				label: info.appLabel || info.packageName,
				uid: info.uid === undefined || info.uid === null ? "" : String(info.uid),
				system: !!info.isSystem,
				icon: true,
			});
		}
	}
	state.apps = apps;
	return apps.length;
}

async function loadAppsFromShell() {
	const result = await run("apps");
	const apps = [];
	for (const line of result.stdout.split(/\r?\n/)) {
		if (!line) {
			continue;
		}
		const parts = line.split("\t");
		if (parts.length < 2) {
			continue;
		}
		apps.push({
			name: parts[0],
			label: parts[0],
			uid: parts[1],
			system: parts[2] === "1",
			icon: false,
		});
	}
	state.apps = apps;
	return apps.length;
}

function appAvatar(app) {
	if (app.icon) {
		const img = document.createElement("img");
		img.className = "app-icon";
		img.loading = "lazy";
		img.decoding = "async";
		img.alt = "";
		img.src = `ksu://icon/${app.name}`;
		img.addEventListener("error", () => {
			img.replaceWith(appAvatarFallback(app));
		});
		return img;
	}
	return appAvatarFallback(app);
}

function appAvatarFallback(app) {
	const span = document.createElement("span");
	span.className = "app-icon app-icon-ph";
	span.textContent = (app.label || app.name || "?").slice(0, 1).toUpperCase();
	return span;
}

function renderApps() {
	const fragment = document.createDocumentFragment();
	for (const app of state.apps) {
		const row = document.createElement("label");
		row.className = "app-row";
		row.dataset.name = app.name;
		row.dataset.label = app.label || app.name;
		row.dataset.system = app.system ? "1" : "0";

		const check = document.createElement("input");
		check.type = "checkbox";
		check.className = "app-check";
		check.checked = state.selected.has(app.name);
		check.addEventListener("change", () => {
			if (check.checked) {
				state.selected.add(app.name);
			} else {
				state.selected.delete(app.name);
			}
			updateSelectionUi();
		});

		const meta = document.createElement("span");
		meta.className = "app-meta";
		const name = document.createElement("span");
		name.className = "app-name";
		name.textContent = app.label || app.name;
		const sub = document.createElement("span");
		sub.className = "app-sub";
		sub.textContent = app.uid === "" || app.uid === app.name
			? app.name
			: `${app.name} · uid ${app.uid}`;
		meta.appendChild(name);
		meta.appendChild(sub);

		row.appendChild(check);
		row.appendChild(appAvatar(app));
		row.appendChild(meta);
		if (app.system) {
			const tag = document.createElement("span");
			tag.className = "tag";
			tag.textContent = "系统";
			row.appendChild(tag);
		}
		fragment.appendChild(row);
	}
	els.appList.replaceChildren(fragment);
	applyFilter();
	updateSelectionUi();
}

function syncRows() {
	for (const row of els.appList.querySelectorAll(".app-row")) {
		const check = row.querySelector(".app-check");
		check.checked = state.selected.has(row.dataset.name);
	}
}

function applyFilter() {
	const needle = els.searchInput.value.trim().toLowerCase();
	let visible = 0;
	for (const row of els.appList.querySelectorAll(".app-row")) {
		/* 软件名和包名都能搜 */
		const haystack = `${row.dataset.label || ""} ${row.dataset.name || ""}`.toLowerCase();
		const matchesText = !needle || haystack.includes(needle);
		const matchesSystem = state.filterSystem || row.dataset.system !== "1";
		const show = matchesText && matchesSystem;
		row.hidden = !show;
		if (show) {
			visible++;
		}
	}
	if (!state.apps.length) {
		els.listHint.textContent = "没有读取到应用列表";
	} else if (!visible) {
		els.listHint.textContent = "没有匹配的应用";
	}
	return visible;
}

function updateSelectionUi() {
	els.selCount.textContent = `已选 ${state.selected.size}`;
	const dirty = isDirty();
	els.saveBtn.disabled = state.busy || !dirty;
	els.saveBtn.classList.toggle("dirty", dirty);
	els.saveBtn.textContent = dirty ? "保存选择 *" : "保存选择";

	const visible = applyFilter();
	const missing = (state.status.missing || "").split(",").filter(Boolean);
	if (dirty) {
		els.listHint.textContent = `有未保存的更改 (${state.selected.size} 个应用)`;
	} else if (missing.length) {
		els.listHint.textContent = `${missing.length} 个已选应用当前未安装`;
	} else if (state.apps.length && visible) {
		els.listHint.textContent = state.hasAppInfo
			? `共 ${state.apps.length} 个应用`
			: `共 ${state.apps.length} 个应用 (当前管理器没有应用信息接口, 只显示包名)`;
	}
}

/* ------------------------------------------------------------------ */
/* 操作                                                                */
/* ------------------------------------------------------------------ */

async function refreshAll(showError = true) {
	setBusy(true);
	try {
		await refreshStatus();
		await refreshLogs();
	} catch (error) {
		if (showError) {
			showToast(error.message, true);
		}
	} finally {
		setBusy(false);
	}
}

async function toggleModule() {
	if (state.busy) {
		return;
	}
	const loaded = state.status.loaded === "1";
	const action = loaded ? "stop" : "start";
	setBusy(true);
	try {
		const result = await run(action);
		showToast(result.stdout.trim() || (action === "start" ? "已启用" : "已停用"));
		await refreshStatus();
		await refreshLogs();
	} catch (error) {
		showToast(error.message, true);
		await refreshStatus().catch(() => {});
		await refreshLogs().catch(() => {});
	} finally {
		setBusy(false);
	}
}

async function saveSelection() {
	if (state.busy) {
		return;
	}
	setBusy(true);
	try {
		const csv = Array.from(state.selected).sort().join(",");
		await run(`set packages '${csv}'`);
		state.saved = new Set(state.selected);
		const result = await run("apply");
		showToast(result.stdout.trim() || "选择已保存");
		await refreshStatus();
		await refreshLogs();
	} catch (error) {
		showToast(error.message, true);
	} finally {
		setBusy(false);
		updateSelectionUi();
	}
}

async function setFlag(key, value, element) {
	if (state.busy) {
		return;
	}
	setBusy(true);
	try {
		const result = await run(`set ${key} ${value ? "1" : "0"}`);
		showToast(result.stdout.trim() || "设置已应用");
		await refreshStatus();
	} catch (error) {
		element.checked = !element.checked;
		showToast(error.message, true);
		await refreshStatus().catch(() => {});
	} finally {
		setBusy(false);
	}
}

/* ------------------------------------------------------------------ */
/* 事件绑定                                                            */
/* ------------------------------------------------------------------ */

els.toggleBtn.addEventListener("click", () => {
	void toggleModule();
});

els.saveBtn.addEventListener("click", () => {
	void saveSelection();
});

els.autoStartSwitch.addEventListener("change", (event) => {
	void setFlag("auto_start", event.target.checked, els.autoStartSwitch);
});

els.searchInput.addEventListener("input", () => {
	updateSelectionUi();
});

els.sysToggle.addEventListener("change", (event) => {
	state.filterSystem = event.target.checked;
	updateSelectionUi();
});

els.refreshLogsBtn.addEventListener("click", () => {
	void refreshAll();
});

document.addEventListener("visibilitychange", () => {
	if (!document.hidden) {
		void refreshAll(false);
	}
});

window.setInterval(() => {
	if (!document.hidden) {
		void refreshLogs().catch(() => {});
	}
}, 6000);

/* ------------------------------------------------------------------ */
/* 启动                                                                */
/* ------------------------------------------------------------------ */

async function resolveModuleDir() {
	for (const dir of CANDIDATE_DIRS) {
		const result = await ksuExec(`[ -f ${dir}/control.sh ] && echo yes`, api.threeArgs);
		if (result.stdout.indexOf("yes") !== -1) {
			return dir;
		}
	}
	return CANDIDATE_DIRS[0];
}

async function boot() {
	try {
		await detectApi();
		MODDIR = await resolveModuleDir();
		await refreshStatus();
		applySelectionFromStatus();
		await loadApps();
		applySelectionFromStatus();
		await refreshLogs();
	} catch (error) {
		els.masterHint.textContent = error.message;
		els.listHint.textContent = error.message;
		showToast(error.message, true);
	}
}

void boot();
