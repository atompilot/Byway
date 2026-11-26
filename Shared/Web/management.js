"use strict";

const messages = {
  en: {
    title: "Byway Management", copy: "Copy page link", connectDevice: "Connect to a device",
    accessToken: "Access token", connect: "Connect", refresh: "Refresh", disconnect: "Disconnect page",
    proxyStatus: "Proxy status", connection: "Connection", currentNode: "Current node",
    routingProfile: "Routing profile", deviceInfo: "Device information", device: "Device",
    systemVersion: "OS version", appVersion: "Byway version", rename: "Rename device",
    deviceName: "Device name", save: "Save", discovery: "LAN discovery", openIp: "Open IP address",
    pageLink: "Management page link", invalidToken: "The access token is invalid or has expired.",
    requestFailed: "Request failed (HTTP {0}).", deviceCode: "Device code {0}", unknown: "Unknown",
    invalidName: "Enter a device name of 1–80 characters without line breaks or control characters.",
    discoveryOff: "Off", discoveryWaiting: "Waiting for the network",
    discoveryPublishing: "Publishing mDNS address", discoveryPublished: "mDNS address published",
    discoveryUnavailable: "mDNS unavailable. Use the IP address.", unavailable: "Status unavailable",
    disableDiscovery: "Disable discovery", enableDiscovery: "Enable discovery",
    profileSelected: "Selected profile", profileInactive: "{0} (not in use)",
    connected: "Connected", disconnected: "Disconnected", defaultRouting: "Default routing",
    hotspotRouting: "Hotspot proxy", offline: "Could not reach Byway. Check the device and local network.",
    savedName: "Device name saved.", copied: "Page link copied."
  },
  "zh-Hans": {
    title: "Byway 管理", copy: "复制网页链接", connectDevice: "连接设备", accessToken: "访问令牌",
    connect: "连接", refresh: "刷新", disconnect: "断开网页连接", proxyStatus: "代理状态",
    connection: "连接", currentNode: "当前节点", routingProfile: "分流配置", deviceInfo: "设备信息",
    device: "设备", systemVersion: "系统版本", appVersion: "Byway 版本", rename: "修改设备名称",
    deviceName: "设备名称", save: "保存", discovery: "局域网发现", openIp: "打开 IP 地址",
    pageLink: "管理网页链接", invalidToken: "访问令牌无效或已失效。",
    requestFailed: "请求失败（HTTP {0}）。", deviceCode: "识别码 {0}", unknown: "未知",
    invalidName: "设备名称需要 1 至 80 个字符，且不能包含换行或控制字符。",
    discoveryOff: "已关闭", discoveryWaiting: "等待局域网", discoveryPublishing: "正在发布 mDNS 地址",
    discoveryPublished: "已发布 mDNS 地址", discoveryUnavailable: "mDNS 不可用，请使用 IP 地址。",
    unavailable: "状态不可用", disableDiscovery: "关闭发现", enableDiscovery: "开启发现",
    profileSelected: "已选配置", profileInactive: "{0}（当前未应用）", connected: "已连接",
    disconnected: "未连接", defaultRouting: "默认分流", hotspotRouting: "热点代理",
    offline: "无法连接到 Byway，请检查设备和局域网。", savedName: "设备名称已保存。",
    copied: "网页链接已复制。"
  },
  es: {
    title: "Administración de Byway", copy: "Copiar enlace", connectDevice: "Conectar con un dispositivo",
    accessToken: "Token de acceso", connect: "Conectar", refresh: "Actualizar",
    disconnect: "Cerrar sesión", proxyStatus: "Estado del proxy", connection: "Conexión",
    currentNode: "Nodo actual", routingProfile: "Perfil de enrutamiento",
    deviceInfo: "Información del dispositivo", device: "Dispositivo", systemVersion: "Versión del sistema",
    appVersion: "Versión de Byway", rename: "Cambiar el nombre del dispositivo", deviceName: "Nombre del dispositivo",
    save: "Guardar", discovery: "Detección en la red local", openIp: "Abrir dirección IP",
    pageLink: "Enlace de administración", invalidToken: "El token de acceso no es válido o ha caducado.",
    requestFailed: "La solicitud falló (HTTP {0}).", deviceCode: "Código del dispositivo {0}", unknown: "Desconocido",
    invalidName: "Introduce un nombre de 1 a 80 caracteres, sin saltos de línea ni caracteres de control.",
    discoveryOff: "Desactivada", discoveryWaiting: "Esperando a la red local",
    discoveryPublishing: "Publicando la dirección mDNS", discoveryPublished: "Dirección mDNS publicada",
    discoveryUnavailable: "mDNS no está disponible. Usa la dirección IP.", unavailable: "Estado no disponible",
    disableDiscovery: "Desactivar detección", enableDiscovery: "Activar detección",
    profileSelected: "Perfil seleccionado", profileInactive: "{0} (sin aplicar)",
    connected: "Conectado", disconnected: "Desconectado", defaultRouting: "Enrutamiento predeterminado",
    hotspotRouting: "Proxy del punto de acceso",
    offline: "No se pudo acceder a Byway. Comprueba el dispositivo y la red local.",
    savedName: "Nombre del dispositivo guardado.", copied: "Enlace copiado."
  }
};

const language = (navigator.languages ?? [navigator.language])
  .map((tag) => ({ zh: "zh-Hans", es: "es", en: "en" })[tag.split("-")[0].toLowerCase()])
  .find(Boolean) || "en";
const labels = messages[language];
const message = (key, ...values) => labels[key].replace(/\{(\d+)\}/g, (_, index) => values[index] ?? "");
document.documentElement.lang = language;
document.title = labels.title;
document.querySelectorAll("[data-message]").forEach((element) => {
  element.textContent = labels[element.dataset.message];
});
document.querySelectorAll("[data-message-label]").forEach((element) => {
  element.setAttribute("aria-label", labels[element.dataset.messageLabel]);
});

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
    throw new Error(labels.invalidToken);
  }
  if (!response.ok) {
    if (path === "/v1/device" && options.method === "PATCH" && [400, 422].includes(response.status)) {
      throw new Error(labels.invalidName);
    }
    const body = language === "zh-Hans" ? await response.json().catch(() => ({})) : {};
    throw new Error(body.error || message("requestFailed", response.status));
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
  el("device-code").textContent = message("deviceCode", device.id.slice(0, 8).toUpperCase());
  el("hardware").textContent = device.modelIdentifier || device.type;
  el("system").textContent = device.osVersion || labels.unknown;
  el("version").textContent = device.appVersion || labels.unknown;
  el("name").value = device.displayName;
}

const discoveryStatus = {
  off: labels.discoveryOff, waiting: labels.discoveryWaiting, publishing: labels.discoveryPublishing,
  published: labels.discoveryPublished, unavailable: labels.discoveryUnavailable
};

function renderDiscovery(state) {
  clearTimeout(discoveryTimer);
  discovery = state;
  copyUrl = state?.mdnsUrl || state?.ipUrl || url;
  el("discovery").hidden = !state;
  if (!state) return;
  el("discovery-status").textContent = discoveryStatus[state.status] || labels.unavailable;
  el("discovery-toggle").textContent = state.enabled ? labels.disableDiscovery : labels.enableDiscovery;
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
        routing = message("profileInactive", routing || labels.profileSelected);
      }
    }
  }
  if (!token) throw new Error(labels.invalidToken);
  const settings = await request("/v1/discovery").catch(() => null);
  if (!token) throw new Error(labels.invalidToken);
  renderDiscovery(settings);
  renderDevice(status.deviceInfo || device);
  el("connected").textContent = status.connected === true ? labels.connected :
    status.connected === false ? labels.disconnected : labels.unavailable;
  el("node").textContent = node || "—";
  el("routing").textContent = linux && routing === "热点代理" ? labels.hotspotRouting : routing || (linux ? "—" : labels.defaultRouting);
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
    el("notice").textContent = error instanceof TypeError ? labels.offline : error.message;
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
    el("notice").textContent = labels.savedName;
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
    el("notice").textContent = labels.copied;
  } catch {
    el("notice").textContent = copyUrl;
  }
});
