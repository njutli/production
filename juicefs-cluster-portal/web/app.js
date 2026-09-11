const byId = (id) => document.getElementById(id);
const state = { view: "overview", node: "150", namespaceRoot: "", refreshing: false, identity: null, refreshTimer: null };

const escapeHtml = (value) => String(value ?? "—")
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;")
  .replaceAll("'", "&#039;");

const number = (value, digits = 1) => Number.isFinite(value) ? value.toFixed(digits) : "—";

const formatRate = (value) => {
  if (!Number.isFinite(value)) return "—";
  if (value >= 1e9) return `${(value / 1e9).toFixed(2)} GB/s`;
  if (value >= 1e6) return `${(value / 1e6).toFixed(1)} MB/s`;
  if (value >= 1e3) return `${(value / 1e3).toFixed(1)} kB/s`;
  return `${value.toFixed(0)} B/s`;
};

const formatBytes = (value) => {
  if (!Number.isFinite(value)) return "—";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let scaled = value;
  let unit = 0;
  while (scaled >= 1024 && unit < units.length - 1) {
    scaled /= 1024;
    unit += 1;
  }
  return `${scaled.toFixed(unit > 1 ? 1 : 0)} ${units[unit]}`;
};

const formatLatency = (seconds) => {
  if (!Number.isFinite(seconds)) return "—";
  if (seconds < 0.001) return `${(seconds * 1e6).toFixed(0)} µs`;
  return `${(seconds * 1e3).toFixed(2)} ms`;
};

const formatDuration = (seconds) => {
  if (!Number.isFinite(seconds)) return "—";
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  return days > 0 ? `${days} 天 ${hours} 小时` : `${hours} 小时`;
};

const statusLabel = (status) => ({
  healthy: "正常", normal: "正常", up: "正常", fresh: "正常", warning: "告警",
  degraded: "异常", unavailable: "不可用", unknown: "未知", stale: "过期",
}[String(status).toLowerCase()] || String(status).toUpperCase());

const statusClass = (status) => {
  const normalized = String(status).toLowerCase();
  if (["healthy", "normal", "up", "fresh"].includes(normalized)) return "ok";
  if (["warning", "degraded"].includes(normalized)) return "warn";
  return "bad";
};

const badge = (status) => `<span class="badge ${statusClass(status)}">${escapeHtml(statusLabel(status))}</span>`;

async function api(path, options = {}) {
  const response = await fetch(path, { credentials: "same-origin", ...options });
  if (response.status === 401) {
    showLogin();
    throw new Error("登录已失效，请重新登录");
  }
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(body.detail || `${path}: HTTP ${response.status}`);
  }
  if (response.status === 204) return null;
  return response.json();
}

function stopRefreshTimer() {
  if (state.refreshTimer !== null) {
    clearInterval(state.refreshTimer);
    state.refreshTimer = null;
  }
}

function showLogin(message = "") {
  stopRefreshTimer();
  state.identity = null;
  byId("admin-shell").hidden = true;
  byId("user-screen").hidden = true;
  byId("login-screen").hidden = false;
  byId("password").value = "";
  const error = byId("login-error");
  error.textContent = message;
  error.hidden = !message;
  byId("username").focus();
}

function showUser(identity) {
  stopRefreshTimer();
  state.identity = identity;
  byId("login-screen").hidden = true;
  byId("admin-shell").hidden = true;
  byId("user-screen").hidden = false;
  byId("user-identity").textContent = `${identity.subject} · ${identity.role}`;
  state.namespaceRoot = "";
  refreshUserUsage();
  state.refreshTimer = setInterval(refreshUserUsage, 30000);
}

function showAdmin(identity) {
  state.identity = identity;
  byId("login-screen").hidden = true;
  byId("user-screen").hidden = true;
  byId("admin-shell").hidden = false;
  byId("identity").textContent = `${identity.subject} · ${identity.role}`;
  stopRefreshTimer();
  refresh();
  state.refreshTimer = setInterval(refresh, 5000);
}

function applyIdentity(identity) {
  if (identity.role === "ADMIN") {
    showAdmin(identity);
    return;
  }
  showUser(identity);
}

async function restoreSession() {
  try {
    applyIdentity(await api("/api/v1/me"));
  } catch (cause) {
    if (!byId("login-screen").hidden) return;
    showLogin(cause.message);
  }
}

async function login(event) {
  event.preventDefault();
  const button = byId("login");
  const error = byId("login-error");
  error.hidden = true;
  button.disabled = true;
  try {
    const identity = await api("/api/v1/session", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: byId("username").value, password: byId("password").value }),
    });
    byId("password").value = "";
    applyIdentity(identity);
  } catch (cause) {
    showLogin(cause.message);
  } finally {
    button.disabled = false;
  }
}

async function logout() {
  try {
    await api("/api/v1/session", { method: "DELETE" });
  } catch (_) {
    // A missing or expired server session still ends the local browser session.
  }
  showLogin();
}

function showMeta(sample, label = "监控数据") {
  const freshness = sample?.freshness || "unavailable";
  const age = Number.isFinite(sample?.ageSeconds) ? `${sample.ageSeconds.toFixed(1)}s` : "—";
  byId("freshness").textContent = `${label} · ${statusLabel(freshness)} · 年龄 ${age} · ${sample?.collectedAt || "无时间戳"}`;
}

function showHealth(message, status) {
  byId("cluster-health").textContent = message;
  byId("health-dot").className = `health-dot ${statusClass(status)}`;
}

function renderNodesRows(nodes) {
  return nodes.map((node) => `
    <tr>
      <td><strong>${escapeHtml(node.hostname)}</strong><br><small>${escapeHtml(node.ip)}</small></td>
      <td>${node.roles.map(escapeHtml).join(" · ")}</td>
      <td>${number(node.cpuPercent)}%</td>
      <td>${formatBytes(node.memoryAvailableBytes)}</td>
      <td>${formatRate(node.networkRxBps)}<br><small>${formatRate(node.networkTxBps)}</small></td>
      <td>${badge(node.status)}</td>
    </tr>
  `).join("");
}

function renderOverview(payload) {
  const overview = payload.data;
  const healthy = overview.health === "healthy";
  showHealth(healthy ? "全部核心组件正常" : "集群存在异常或数据缺失", overview.health);
  showMeta(payload.sample);
  byId("jfs-read").textContent = formatRate(overview.bandwidth.juicefsLogicalReadBps);
  byId("jfs-write").textContent = formatRate(overview.bandwidth.juicefsLogicalWriteBps);
  byId("ceph-read").textContent = formatRate(overview.bandwidth.cephPhysicalReadBps);
  byId("ceph-write").textContent = formatRate(overview.bandwidth.cephPhysicalWriteBps);
  byId("components").innerHTML = Object.entries(overview.components).map(([name, item]) => {
    const healthyCount = item.healthy ?? item.clean;
    const normal = Number.isFinite(healthyCount) && Number.isFinite(item.total) && healthyCount === item.total;
    return `<div class="component"><div><strong>${escapeHtml(name.toUpperCase())}</strong><small>${healthyCount ?? "—"} / ${item.total ?? "—"}</small></div>${badge(normal ? "healthy" : "warning")}</div>`;
  }).join("");
}

function findNode(nodes, id) {
  return nodes.find((node) => node.id === id);
}

function topoCard(node) {
  if (!node) return "";
  return `<div class="topo-node ${statusClass(node.status)}"><strong>${escapeHtml(node.label)}</strong><small>${escapeHtml(node.detail || node.kind)}</small></div>`;
}

function renderTopology(payload, target, compact = false) {
  const nodes = payload.data.nodes;
  const tikv = nodes.filter((node) => node.kind === "tikv");
  const osds = nodes.filter((node) => node.kind === "osd");
  const healthyTiKV = tikv.filter((node) => node.status === "healthy").length;
  const healthyOSD = osds.filter((node) => node.status === "healthy").length;
  if (compact) {
    const tikvSummary = { label: `TiKV ${healthyTiKV}/${tikv.length}`, kind: "store", status: healthyTiKV === tikv.length ? "healthy" : "warning" };
    const osdSummary = { label: `OSD ${healthyOSD}/${osds.length}`, kind: "NVMe", status: healthyOSD === osds.length ? "healthy" : "warning" };
    byId(target).innerHTML = `
      <div class="topology-lane"><span class="lane-label">元数据</span>${topoCard(findNode(nodes, "client-157"))}<span class="arrow">→</span>${topoCard(findNode(nodes, "volume-prod"))}<span class="arrow">→</span>${topoCard(findNode(nodes, "pd-cluster"))}<span class="arrow">→</span>${topoCard(tikvSummary)}</div>
      <div class="topology-lane"><span class="lane-label">对象数据</span>${topoCard(findNode(nodes, "client-157"))}<span class="arrow">→</span>${topoCard(findNode(nodes, "ceph-control"))}<span class="arrow">→</span>${topoCard(findNode(nodes, "ceph-pool"))}<span class="arrow">→</span>${topoCard(osdSummary)}</div>
    `;
    return;
  }
  const groups = [
    ["入口与卷", nodes.filter((node) => ["client", "volume"].includes(node.kind))],
    ["元数据", nodes.filter((node) => ["pd", "tikv"].includes(node.kind))],
    ["Ceph 控制与 Pool", nodes.filter((node) => ["ceph", "pool"].includes(node.kind))],
    ["OSD 与物理盘", nodes.filter((node) => ["osd", "disk"].includes(node.kind))],
  ];
  const mappings = payload.data.edges.filter((edge) => edge.relation === "uses").map((edge) => `<span><strong>${escapeHtml(edge.from.toUpperCase())}</strong> → ${escapeHtml(findNode(nodes, edge.to)?.label)}</span>`).join("");
  byId(target).innerHTML = groups.map(([label, items]) => `
    <div class="topology-group"><span class="lane-label">${label}</span><div class="topology-cards">${items.map(topoCard).join("")}</div></div>
  `).join("") + `<div class="mapping-strip">${mappings}</div>`;
}

function renderDisks(payload) {
  showHealth(`节点 ${state.node} 磁盘指标在线`, payload.sample.freshness);
  showMeta(payload.sample, `节点 ${state.node}`);
  byId("disks").innerHTML = payload.data.map((disk) => `
    <tr>
      <td><strong>${escapeHtml(disk.device)}</strong><br><small>${escapeHtml(disk.purpose)}${disk.cephDaemon ? ` · ${escapeHtml(disk.cephDaemon.toUpperCase())}` : ""}${disk.mountpoint ? ` · ${escapeHtml(disk.mountpoint)}` : ""}</small></td>
      <td>${escapeHtml(disk.model)}<br><small>${escapeHtml(disk.serial)} · ${escapeHtml(disk.firmware)}</small></td>
      <td>${formatBytes(disk.sizeBytes)}</td>
      <td>${formatRate(disk.readBps)}<br><small>${formatRate(disk.writeBps)}</small></td>
      <td>${number(disk.readIops, 0)} / ${number(disk.writeIops, 0)}<br><small>${formatLatency(disk.latencySeconds)}</small></td>
      <td>${number(disk.utilPercent)}%<br><small>queue ${number(disk.queueDepth, 2)}</small></td>
      <td>${number(disk.temperatureC, 0)} °C<br><small>寿命消耗 ${Number.isFinite(disk.percentageUsedRatio) ? (disk.percentageUsedRatio * 100).toFixed(0) + "%" : "—"}</small></td>
      <td>${badge(disk.status)}<br><small>media ${number(disk.mediaErrors, 0)}</small></td>
    </tr>
  `).join("");
}

function card(title, rows, tone = "") {
  return `<article class="panel detail-card ${tone}"><div class="panel-title"><span>${escapeHtml(title)}</span></div><dl>${rows.map(([key, value]) => `<div><dt>${escapeHtml(key)}</dt><dd>${value}</dd></div>`).join("")}</dl></article>`;
}

function renderClients(payload) {
  const client = payload.data[0];
  showHealth(client?.status === "healthy" ? "JuiceFS 客户端在线" : "JuiceFS 客户端异常", client?.status);
  showMeta(payload.sample, "JuiceFS");
  if (!client) {
    byId("clients-content").innerHTML = '<p class="empty">没有客户端样本</p>';
    return;
  }
  const object = client.object || {};
  const cache = client.cache || {};
  const writeback = client.writeback || {};
  const process = client.process || {};
  byId("clients-content").innerHTML =
    card("客户端", [["主机", escapeHtml(client.hostname)], ["挂载点", escapeHtml(client.mountpoint)], ["版本", escapeHtml(client.version)], ["运行时间", escapeHtml(formatDuration(client.uptimeSeconds))], ["状态", badge(client.status)]]) +
    card("FUSE 逻辑 I/O", [["读带宽", escapeHtml(formatRate(client.io.readBps))], ["写带宽", escapeHtml(formatRate(client.io.writeBps))], ["读 / 写 IOPS", `${number(client.io.readIops, 0)} / ${number(client.io.writeIops, 0)}`], ["平均延迟", escapeHtml(formatLatency(client.io.averageFuseLatencySeconds))]]) +
    card("对象请求", [["GET / PUT", `${formatRate(object.getBps)} / ${formatRate(object.putBps)}`], ["请求率", `${number(object.getRate)} / ${number(object.putRate)} req/s`], ["GET / PUT 延迟", `${formatLatency(object.getLatencySeconds)} / ${formatLatency(object.putLatencySeconds)}`]]) +
    card("缓存与进程", [["缓存占用", escapeHtml(formatBytes(cache.bytes))], ["命中字节率", Number.isFinite(cache.hitRatioBytes) ? `${(cache.hitRatioBytes * 100).toFixed(1)}%` : "—"], ["Writeback 暂存", escapeHtml(formatBytes(writeback.stagingBytes))], ["CPU / RSS", `${number(process.cpuCores, 2)} 核 / ${formatBytes(process.rssBytes)}`]]);
}

function renderTiKV(payload) {
  const data = payload.data;
  const allUp = data.pd.healthyMembers === data.pd.members && data.stores.every((store) => ["healthy", "up"].includes(String(store.state).toLowerCase()));
  showHealth(allUp ? "PD 与 TiKV 全部在线" : "元数据组件存在异常", allUp ? "healthy" : "warning");
  showMeta(payload.sample, "TiKV / PD");
  const stores = `<article class="panel detail-card wide"><div class="panel-title"><span>TiKV Stores</span></div><div class="table-wrap"><table><thead><tr><th>节点</th><th>状态</th><th>Leader</th><th>Region</th><th>CPU</th><th>内存</th></tr></thead><tbody>${data.stores.map((store) => `<tr><td>${escapeHtml(store.nodeId)}</td><td>${badge(store.state)}</td><td>${number(store.leaderCount, 0)}</td><td>${number(store.regionCount, 0)}</td><td>${number(store.cpuCores, 2)} 核</td><td>${formatBytes(store.rssBytes)}</td></tr>`).join("")}</tbody></table></div></article>`;
  byId("tikv-content").innerHTML =
    card("PD", [["Leader", escapeHtml(data.pd.leader)], ["成员", `${data.pd.healthyMembers} / ${data.pd.members}`]]) +
    card("事务路径", [["Scheduler 平均延迟", escapeHtml(formatLatency(data.schedulerLatencySeconds))], ["Raft Commit 平均延迟", escapeHtml(formatLatency(data.raftCommitLatencySeconds))]]) +
    card("RocksDB", [["Pending Compaction", escapeHtml(formatBytes(data.pendingCompactionBytes))], ["L0 文件", number(data.l0Files, 0)], ["Write Stall", badge(data.writeStall ? "warning" : "healthy")]]) + stores;
}

function renderCeph(payload) {
  const data = payload.data;
  const healthy = data.health === "HEALTH_OK" && data.osd.up === data.osd.total && data.pg.nonClean === 0;
  showHealth(data.health, healthy ? "healthy" : "warning");
  showMeta(payload.sample, "Ceph");
  byId("ceph-content").innerHTML =
    card("集群健康", [["状态", badge(healthy ? "healthy" : "warning")], ["MON Quorum", String(data.monQuorum)], ["Active MGR", escapeHtml(data.mgr.active)], ["Standby", escapeHtml(data.mgr.standbys.join(", ") || "无")]]) +
    card("OSD / PG", [["OSD Up / In", `${data.osd.up} / ${data.osd.in} / ${data.osd.total}`], ["PG Clean", `${data.pg.clean ?? "—"} / ${data.pg.total ?? "—"}`], ["Recovery", escapeHtml(formatRate(data.recoveryBps))], ["Scrub / Deep", `${number(data.scrubbingPgs, 0)} / ${number(data.deepScrubbingPgs, 0)}`]]) +
    card("juicefs-data", [["规格", escapeHtml(data.pool.profile)], ["逻辑存储", escapeHtml(formatBytes(data.pool.storedBytes))], ["Raw 占用", escapeHtml(formatBytes(data.pool.rawUsedBytes))], ["可用", escapeHtml(formatBytes(data.pool.maxAvailableBytes))], ["读 / 写", `${formatRate(data.pool.readBps)} / ${formatRate(data.pool.writeBps)}`]]) +
    card("后端延迟", [["Apply", escapeHtml(formatLatency(data.applyLatencySeconds))], ["Commit", escapeHtml(formatLatency(data.commitLatencySeconds))], ["读 / 写 IOPS", `${number(data.pool.readIops, 0)} / ${number(data.pool.writeIops, 0)}`]]);
}

function renderUsage(payload) {
  const data = payload.data;
  showHealth("容量指标在线", payload.sample.freshness);
  showMeta(payload.sample, "容量");
  const amplification = Number.isFinite(data.pool.rawUsedBytes) && Number.isFinite(data.pool.storedBytes) && data.pool.storedBytes > 0 ? data.pool.rawUsedBytes / data.pool.storedBytes : null;
  byId("usage-content").innerHTML =
    card("JuiceFS 逻辑用量", [["卷", escapeHtml(data.volume.name)], ["已用空间", escapeHtml(formatBytes(data.volume.logicalUsedBytes))], ["已用 inode", Number.isFinite(data.volume.usedInodes) ? data.volume.usedInodes.toLocaleString() : "—"]]) +
    card("Ceph Pool", [["Pool", escapeHtml(data.pool.name)], ["Stored", escapeHtml(formatBytes(data.pool.storedBytes))], ["Raw Used", escapeHtml(formatBytes(data.pool.rawUsedBytes))], ["EC 放大", Number.isFinite(amplification) ? `${amplification.toFixed(2)}×` : "—"]]) +
    card("Ceph 集群 Raw", [["总容量", escapeHtml(formatBytes(data.cluster.rawTotalBytes))], ["已用", escapeHtml(formatBytes(data.cluster.rawUsedBytes))], ["可用", escapeHtml(formatBytes(data.cluster.rawAvailableBytes))]]);
}

function namespaceSampleText(sample) {
  const freshness = sample?.freshness || "unavailable";
  const age = Number.isFinite(sample?.ageSeconds) ? `${sample.ageSeconds.toFixed(1)}s` : "—";
  return `${statusLabel(freshness)} · 年龄 ${age} · ${sample?.collectedAt || "无时间戳"}`;
}

function namespaceRootButtons(roots, prefix) {
  return roots.map((root) => `<button type="button" data-root-id="${escapeHtml(root.id)}" class="${root.id === state.namespaceRoot ? "active" : ""}">${escapeHtml(root.displayName)}</button>`).join("");
}

function renderNamespaceTree(payload, prefix) {
  const { root, entries } = payload.data;
  const target = byId(`${prefix}-usage-content`);
  const kindLabels = { directory: "目录", file: "文件", aggregate: "其余项" };
  const rows = entries.map((entry) => `
    <tr>
      <td><span class="tree-name depth-${Math.min(3, Math.max(0, entry.depth))}">${escapeHtml(entry.name)}</span><small>${escapeHtml(entry.path)}</small></td>
	  <td>${escapeHtml(kindLabels[entry.kind] || entry.kind)}</td>
      <td>${formatBytes(entry.recursiveBytes)}</td>
      <td>${Number(entry.fileCount).toLocaleString()}</td>
      <td>${Number(entry.dirCount).toLocaleString()}</td>
      <td>${entry.modifiedAt ? escapeHtml(entry.modifiedAt) : "—"}</td>
    </tr>`).join("");
  target.innerHTML = `
    <div class="namespace-summary">
      <article><span>递归逻辑用量</span><strong>${formatBytes(root.logicalBytes)}</strong></article>
      <article><span>文件数</span><strong>${Number(root.fileCount).toLocaleString()}</strong></article>
      <article><span>目录数</span><strong>${Number(root.dirCount).toLocaleString()}</strong></article>
    </div>
    <div class="table-wrap namespace-table"><table><thead><tr><th>项目</th><th>类型</th><th>递归逻辑用量</th><th>文件</th><th>目录</th><th>修改时间</th></tr></thead><tbody>${rows || '<tr><td colspan="6" class="loading">快照中没有项目</td></tr>'}</tbody></table></div>`;
  if (prefix === "admin") {
    showHealth(`${root.displayName} 快照可用`, payload.sample.freshness);
    showMeta(payload.sample, "目录用量");
  } else {
    byId("user-usage-freshness").textContent = namespaceSampleText(payload.sample);
  }
}

async function loadNamespaceUsage(prefix) {
  const rootsPayload = await api("/api/v1/usage/roots");
  const roots = rootsPayload.data.roots || [];
  if (roots.length === 0) {
    state.namespaceRoot = "";
    byId(`${prefix}-root-selector`).innerHTML = "";
    byId(`${prefix}-usage-content`).innerHTML = '<div class="empty-state"><strong>没有授权目录</strong><span>请联系管理员配置可查看的根目录。</span></div>';
    if (prefix === "user") byId("user-usage-freshness").textContent = namespaceSampleText(rootsPayload.sample);
    return;
  }
  if (!roots.some((root) => root.id === state.namespaceRoot)) state.namespaceRoot = roots[0].id;
  byId(`${prefix}-root-selector`).innerHTML = namespaceRootButtons(roots, prefix);
  const tree = await api(`/api/v1/usage/tree?rootId=${encodeURIComponent(state.namespaceRoot)}&maxDepth=3`);
  renderNamespaceTree(tree, prefix);
}

async function refreshUserUsage() {
  if (state.refreshing || state.identity?.role !== "USER") return;
  state.refreshing = true;
  byId("user-refresh").disabled = true;
  const error = byId("user-error");
  error.hidden = true;
  try {
    await loadNamespaceUsage("user");
  } catch (cause) {
    error.textContent = `刷新失败：${cause.message}`;
    error.hidden = false;
  } finally {
    state.refreshing = false;
    byId("user-refresh").disabled = false;
  }
}

function renderAlerts(payload) {
  const alerts = payload.data;
  showHealth(alerts.length === 0 ? "当前无活动告警" : `${alerts.length} 条活动告警`, alerts.length === 0 ? "healthy" : "warning");
  showMeta(payload.sample, "告警");
  byId("alerts-content").innerHTML = alerts.length === 0
    ? '<div class="empty-state"><strong>没有活动告警</strong><span>所有已接入数据源均未触发硬阈值。</span></div>'
    : alerts.map((alert) => `<div class="alert-row"><div>${badge(alert.severity === "critical" ? "unavailable" : "warning")}<strong>${escapeHtml(alert.summary)}</strong><small>${escapeHtml(alert.objectRef)} · ${escapeHtml(alert.updatedAt)}</small></div></div>`).join("");
}

async function refreshOverview() {
  const [overview, topology, nodes] = await Promise.all([
    api("/api/v1/admin/overview"),
    api("/api/v1/admin/topology"),
    api("/api/v1/admin/nodes"),
  ]);
  renderOverview(overview);
  renderTopology(topology, "overview-topology", true);
  byId("overview-nodes").innerHTML = renderNodesRows(nodes.data);
}

const loaders = {
  overview: refreshOverview,
  topology: async () => {
    const payload = await api("/api/v1/admin/topology");
    renderTopology(payload, "full-topology");
    showHealth("拓扑实时状态已更新", payload.sample.freshness);
    showMeta(payload.sample, "拓扑");
  },
  storage: async () => renderDisks(await api(`/api/v1/admin/nodes/${state.node}/disks`)),
  clients: async () => renderClients(await api("/api/v1/admin/juicefs/clients")),
  tikv: async () => renderTiKV(await api("/api/v1/admin/tikv")),
  ceph: async () => renderCeph(await api("/api/v1/admin/ceph")),
  usage: async () => renderUsage(await api("/api/v1/admin/usage")),
  directories: async () => loadNamespaceUsage("admin"),
  alerts: async () => renderAlerts(await api("/api/v1/admin/alerts")),
};

async function refresh() {
  if (state.refreshing || state.identity?.role !== "ADMIN") return;
  state.refreshing = true;
  const error = byId("error");
  error.hidden = true;
  byId("refresh").disabled = true;
  try {
    await loaders[state.view]();
  } catch (cause) {
    error.textContent = `刷新失败：${cause.message}`;
    error.hidden = false;
    showHealth("监控数据不可用", "unavailable");
  } finally {
    state.refreshing = false;
    byId("refresh").disabled = false;
  }
}

function switchView(view) {
  state.view = view;
  document.querySelectorAll(".nav-item").forEach((item) => item.classList.toggle("active", item.dataset.view === view));
  document.querySelectorAll(".view").forEach((item) => item.classList.toggle("active", item.id === `view-${view}`));
  const section = byId(`view-${view}`);
  byId("page-title").textContent = section.dataset.title;
  byId("page-eyebrow").textContent = section.dataset.eyebrow;
  refresh();
}

document.querySelectorAll(".nav-item").forEach((item) => item.addEventListener("click", () => switchView(item.dataset.view)));
byId("refresh").addEventListener("click", refresh);
byId("login-form").addEventListener("submit", login);
document.querySelectorAll(".logout").forEach((button) => button.addEventListener("click", logout));
byId("user-refresh").addEventListener("click", refreshUserUsage);
["user-root-selector", "admin-root-selector"].forEach((id) => byId(id).addEventListener("click", (event) => {
  const button = event.target.closest("[data-root-id]");
  if (!button || button.dataset.rootId === state.namespaceRoot) return;
  state.namespaceRoot = button.dataset.rootId;
  if (state.identity?.role === "ADMIN") refresh(); else refreshUserUsage();
}));
byId("node-selector").innerHTML = ["150", "151", "152"].map((node) => `<button type="button" data-node="${node}" class="${node === state.node ? "active" : ""}">节点 ${node}</button>`).join("");
byId("node-selector").addEventListener("click", (event) => {
  const button = event.target.closest("[data-node]");
  if (!button) return;
  state.node = button.dataset.node;
  byId("node-selector").querySelectorAll("button").forEach((item) => item.classList.toggle("active", item === button));
  refresh();
});

restoreSession();
