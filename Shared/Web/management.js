"use strict";

const el = (id) => document.getElementById(id);
const url = location.origin + "/";
let token = "";
let busy = false;
let discovery;
let discoveryTimer;
let copyUrl = url;
el("endpoint").textContent = url;

async function request(path, options = {}) {
  const headers = { Authorization: "Bearer " + token };
  if (options.body) headers["Content-Type"] = "application/json";
  const response = await fetch(path, { ...options, headers, cache: "no-store", redirect: "error", credentials: "omit" });
  if (response.status === 401) {
    disconnect();
    throw new Error("访问令牌无效或已失效。");
  }
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(body.error || "请求失败（" + response.status + "）。");
  }
  return response.json();
}

function disconnect() {
  token = "";
  el("token").value = "";
  el("name").value = "";
  renderDiscovery(null);
  el("dashboard").hidden = true;
  el("login").hidden = false;
}

function renderDevice(device) {
  el("device-name").textContent = device.displayName;
  el("device-code").textContent = "识别码 " + device.id.slice(0, 8).toUpperCase();
  el("hardware").textContent = device.modelIdentifier || device.type;
  el("system").textContent = device.osVersion || "未知";
  el("version").textContent = device.appVersion || "未知";
  el("name").value = device.displayName;
}

const discoveryStatus = {
  off: "已关闭", waiting: "等待局域网", publishing: "正在发布 mDNS 地址",
  published: "已发布 mDNS 地址", unavailable: "mDNS 不可用，使用 IP 地址"
};

function renderDiscovery(state) {
  clearTimeout(discoveryTimer);
  discovery = state;
  copyUrl = state?.mdnsUrl || state?.ipUrl || url;
  el("discovery").hidden = !state;
  if (!state) return;
  el("discovery-status").textContent = discoveryStatus[state.status] || "状态不可用";
  el("discovery-toggle").textContent = state.enabled ? "关闭发现" : "开启发现";
  const backup = el("discovery-ip");
  backup.hidden = !state.ipUrl || state.ipUrl === url;
  if (state.ipUrl) backup.href = state.ipUrl;
  else backup.removeAttribute("href");

  if (state.status === "publishing") {
    discoveryTimer = setTimeout(async () => {
      if (!token || busy) return;
      const session = token;
      const next = await request("/v1/discovery").catch(() => null);
      if (next && token === session) renderDiscovery(next);
    }, 1000);
  }
}

async function refresh(device) {
  const status = await request("/v1/status");
  const linux = device.type === "linux";
  let node = status.currentNodeName;
  let routing = status.routingName;
  if (!linux) {
    const [nodes, profiles] = await Promise.allSettled([
      request("/v1/nodes"), request("/v1/config/routing")
    ]);
    const id = status.activeNodeId || status.selectedNodeId || status.selectedNodeID;
    if (id && nodes.status === "fulfilled") {
      node = nodes.value.find((item) => item.id.toLowerCase() === id.toLowerCase())?.name;
    }
    if (profiles.status === "fulfilled") {
      const config = profiles.value;
      const active = config.activeID || config.activeId;
      routing = config.configurations?.find((item) => item.id === active)?.name;
      if (active && status.usesImportedConfiguration === false && status.connected) {
        routing = (routing || "已选配置") + "（当前未应用）";
      }
    }
  }
  if (!token) throw new Error("访问令牌已失效。");
  const settings = await request("/v1/discovery").catch(() => null);
  if (!token) throw new Error("访问令牌已失效。");
  renderDiscovery(settings);
  renderDevice(status.deviceInfo || device);
  el("connected").textContent = status.connected === true ? "已连接" :
    status.connected === false ? "未连接" : "状态不可用";
  el("node").textContent = node || "—";
  el("routing").textContent = routing || (linux ? "—" : "默认分流");
  el("login").hidden = true;
  el("dashboard").hidden = false;
}

async function act(action) {
  if (busy) return;
  busy = true;
  const buttons = document.querySelectorAll("button[type=submit], #refresh, #disconnect, #discovery-toggle");
  buttons.forEach((button) => { button.disabled = true; });
  el("notice").textContent = "";
  try {
    await action();
  } catch (error) {
    el("notice").textContent = error instanceof TypeError ? "无法连接到 Byway，请检查设备和局域网。" : error.message;
  } finally {
    busy = false;
    buttons.forEach((button) => { button.disabled = false; });
  }
}

el("login-form").addEventListener("submit", (event) => {
  event.preventDefault();
  act(async () => {
    token = el("token").value.trim();
    el("token").value = "";
    await refresh(await request("/v1/device"));
  });
});

el("refresh").addEventListener("click", () => act(async () => refresh(await request("/v1/device"))));
el("rename-form").addEventListener("submit", (event) => {
  event.preventDefault();
  act(async () => {
    const device = await request("/v1/device", {
      method: "PATCH", body: JSON.stringify({ displayName: el("name").value })
    });
    renderDevice(device);
    el("notice").textContent = "设备名称已保存。";
  });
});

el("disconnect").addEventListener("click", () => {
  disconnect();
  el("notice").textContent = "";
  el("token").focus();
});

el("discovery-toggle").addEventListener("click", () => {
  if (!discovery) return;
  act(async () => {
    clearTimeout(discoveryTimer);
    const state = await request("/v1/discovery", {
      method: "PATCH", body: JSON.stringify({ enabled: !discovery.enabled })
    });
    renderDiscovery(state);
  });
});

el("copy").addEventListener("click", async () => {
  try {
    if (navigator.clipboard) {
      await navigator.clipboard.writeText(copyUrl);
    } else {
      const field = el("copy-fallback");
      field.value = copyUrl;
      field.focus();
      field.select();
      if (!document.execCommand("copy")) throw new Error("copy");
      el("copy").focus();
    }
    el("notice").textContent = "网页链接已复制。";
  } catch {
    el("notice").textContent = copyUrl;
  }
});
