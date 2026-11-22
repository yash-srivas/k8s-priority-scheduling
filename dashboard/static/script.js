/* ==============================================================================
   KUBEPRIORITY // VIBRANT NEOBRUTALISM CONTROLLER & REAL-TIME TELEMETRY
   VECTOR ICON ENGINE (NO EMOJIS - STRICT SVG & SYMBOLS)
   ============================================================================== */

let autoRefreshInterval = null;
let priorityChart = null;
let latencyChart = null;
let currentFilter = "all";
let cachedPods = [];
let refreshing = false;
let actionRunning = false;
let demoState = null;
let displayedRunIds = null;

document.addEventListener("DOMContentLoaded", () => {
    if (typeof Chart !== "undefined") initCharts();
    refreshAll();
    toggleAutoRefresh(true);
});

function initCharts() {
    // 1. Priority Breakdown Donut Chart (Pink, Cyan, Yellow with 3.5px black borders)
    const ctxPriority = document.getElementById("priorityChart").getContext("2d");
    priorityChart = new Chart(ctxPriority, {
        type: "doughnut",
        data: {
            labels: ["High (100k)", "Medium (50k)", "Low (10k)"],
            datasets: [{
                data: [0, 0, 0],
                backgroundColor: ["#FF3366", "#00D2FF", "#FFE600"],
                borderWidth: 3.5,
                borderColor: "#000000"
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
                legend: {
                    position: "bottom",
                    labels: {
                        color: "#000000",
                        font: { family: "Space Grotesk", weight: "800", size: 12 },
                        boxWidth: 16,
                        boxHeight: 16,
                        padding: 14
                    }
                }
            }
        }
    });

    // 2. Latency Bar Chart (Color-coded bars with 2.5px black borders)
    const ctxLatency = document.getElementById("latencyChart").getContext("2d");
    latencyChart = new Chart(ctxLatency, {
        type: "bar",
        data: {
            labels: [],
            datasets: [{
                label: "Latency (s)",
                data: [],
                backgroundColor: [],
                borderColor: "#000000",
                borderWidth: 2.5
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            scales: {
                y: {
                    beginAtZero: true,
                    grid: { color: "#e2e8f0", lineWidth: 1.5 },
                    ticks: { color: "#000000", font: { family: "JetBrains Mono", weight: "700" } },
                    title: { display: true, text: "Placement Latency (Seconds)", color: "#000000", font: { family: "Space Grotesk", weight: "800" } }
                },
                x: {
                    grid: { display: false },
                    ticks: { color: "#000000", font: { family: "JetBrains Mono", weight: "700", size: 10 } }
                }
            },
            plugins: {
                legend: { display: false }
            }
        }
    });
}

async function refreshAll() {
    if (refreshing) return;
    refreshing = true;
    try {
        await Promise.all([fetchStatus(), fetchPods(), fetchEvents(), fetchResults(), fetchPreemptionAudit()]);
    } finally {
        refreshing = false;
    }
}

function formatMemory(bytes) {
    return (bytes / 2 ** 20).toFixed(1) + " MiB";
}

function showGauge(id, value, allocatable, percentage) {
    document.getElementById(id + "GaugeText").textContent =
        percentage == null ? "--" : value + " / " + allocatable + " (" + percentage + "%)";
    document.getElementById(id + "ProgressBar").style.width =
        Math.max(0, Math.min(100, percentage ?? 0)) + "%";
}

async function fetchStatus() {
    const nodeInfo = document.getElementById("clusterNodeInfo");
    const badge = document.getElementById("hwNodeBadge");
    const dot = document.getElementById("statusDot");
    const title = document.getElementById("clusterStatusText");
    const metrics = document.getElementById("metricsStatus");
    const rows = document.getElementById("nodeTableBody");
    const classes = document.getElementById("priorityClassTable");
    try {
        const res = await fetch("/api/status");
        const data = await res.json();
        if (!data.connected) throw new Error(data.error || "The kind API is unreachable.");
        dot.className = "status-indicator " + (data.topology_ready ? "online" : "offline");
        title.textContent = data.topology_ready ? "CLUSTER: ONLINE" : "CLUSTER: CHECK NODES";
        title.style.color = "";
        nodeInfo.textContent = "CLUSTER " + data.cluster + " / CONTEXT " + data.context;
        badge.textContent = data.nodes.length + " NODES / " +
            data.nodes.filter(node => node.eligible_worker).length + " SCHEDULABLE WORKERS";
        const r = data.resources;
        showGauge("cpu", r.committed_cpu_milli + "m", r.total_cpu_milli + "m", r.cpu_percentage);
        showGauge("mem", formatMemory(r.requested_memory_bytes), formatMemory(r.allocatable_memory_bytes),
            r.memory_percentage);
        metrics.textContent = data.metrics_message;
        rows.replaceChildren();
        for (const node of data.nodes) {
            const tier = node.cpu_by_tier;
            const row = rows.insertRow();
            const role = node.role === "Worker" && !node.eligible_worker ? "Worker (blocked)" : node.role;
            const cells = [
                node.name, role + " / " + node.ready, node.capacity_cpu + " / " + node.capacity_memory,
                node.allocatable_cpu + " / " + node.allocatable_memory,
                node.requested_cpu_milli + "m / " + formatMemory(node.requested_memory_bytes),
                "High " + tier.high + "m / Med " + tier.medium + "m / Low " + tier.low +
                    "m / Other " + tier.other + "m / Free " + node.free_cpu_milli + "m",
                node.usage ? node.usage.cpu + " / " + node.usage.memory : "Unavailable"
            ];
            cells.forEach(value => { row.insertCell().textContent = value; });
        }
        classes.replaceChildren();
        const classOrder = ["high-priority", "medium-priority", "low-priority", "order-high-priority", "order-low-priority"];
        for (const name of classOrder) {
            const pc = data.priority_classes.find(entry => entry.name === name);
            if (!pc) continue;
            const row = classes.insertRow();
            row.insertCell().innerHTML = getPriorityBadge(pc.name);
            [pc.value, pc.policy, pc.global_default ? "Yes" : "No", pc.description].forEach(value => {
                row.insertCell().textContent = value;
            });
        }
    } catch (err) {
        dot.className = "status-indicator offline";
        title.textContent = "CLUSTER: UNAVAILABLE";
        title.style.color = "#FF2A4B";
        nodeInfo.textContent = "CHECK KIND CONTEXT";
        badge.textContent = "NODES: UNAVAILABLE";
        showGauge("cpu", "", "", null);
        showGauge("mem", "", "", null);
        rows.replaceChildren();
        classes.replaceChildren();
        metrics.textContent = err.message;
    }
}

async function fetchResults() {
    const line = document.getElementById("experimentOutcomes");
    try {
        const res = await fetch("/api/results");
        const data = await res.json();
        if (data.error) throw new Error(data.error);
        renderSavedEvidence(data.outcomes, data.timelines);
        line.textContent = "Saved runs below. The Pod table shows the live cluster.";
        if (!Object.keys(data.outcomes).length) line.textContent = "No saved run for this context yet.";
    } catch (err) {
        line.textContent = "Saved outcomes unavailable. " + err.message;
        document.getElementById("savedEvidence").replaceChildren();
        displayedRunIds = null;
    }
}

function renderSavedEvidence(outcomes, timelines) {
    const labels = {"experiment-1": "Normal placement", "scheduling-order": "Scheduling order"};
    const runIds = JSON.stringify(outcomes);
    if (runIds === displayedRunIds) return;
    displayedRunIds = runIds;
    const panel = document.getElementById("savedEvidence");
    panel.replaceChildren();
    for (const [key, label] of Object.entries(labels)) {
        const saved = outcomes[key];
        if (!saved) continue;
        const card = document.createElement("details");
        card.className = "lab-details";
        const summary = document.createElement("summary");
        summary.textContent = label + " · " + saved.status + " · " + new Date(saved.recorded_at).toLocaleString();
        card.appendChild(summary);
        const lines = [saved.message];
        const details = saved.details;
        if (details?.preparation && details?.pendingDemonstrated) {
            const prep = details.preparation;
            lines.push(prep.node + ": " + prep.allocatableCpuMilli + "m allocatable, " +
                details.freeBeforeReleaseMilli + "m free with blocker, " + prep.candidateCpuMilli +
                "m requested by each contestant, and " + details.freeWithBlockerRemovedMilli +
                "m available after the blocker was removed. High: " + (details.highPhase || "unobserved") +
                ". Low: " + (details.lowPhase || "unobserved") + ".");
        }
        for (const text of lines) {
            const paragraph = document.createElement("p");
            paragraph.textContent = text;
            card.appendChild(paragraph);
        }
        const events = timelines[key] || [];
        if (events.length) {
            const heading = document.createElement("p");
            heading.textContent = "Observed scheduler timeline by event creation time. Ties may share a timestamp.";
            card.appendChild(heading);
            const list = document.createElement("ol");
            for (const event of events) {
                const item = document.createElement("li");
                item.textContent = (event.FirstTimestamp || event.LastTimestamp) + " · " + event.Reason + " · " +
                    event.InvolvedObject + " · " + event.Message;
                list.appendChild(item);
            }
            card.appendChild(list);
        }
        panel.appendChild(card);
    }
}

function updateDemoControls() {
    const active = demoState?.active_experiments ?? [];
    const allow = experiment => demoState?.success && active.every(stage => stage === experiment);
    document.getElementById("btnExp1").disabled = actionRunning || !allow("experiment-1");
    updatePreemptionControls(actionRunning || !allow("experiment-2"));
    document.getElementById("btnOrderPrepare").disabled = actionRunning || !allow("scheduling-order") ||
        cachedPods.some(p => p.labels?.role === "blocker" && p.labels?.experiment === "scheduling-order");
    document.getElementById("btnOrderRelease").disabled = actionRunning || !demoState?.order_pending;
    document.getElementById("btnCleanup").disabled = actionRunning;
    document.getElementById("liveStage").textContent = demoState?.order_pending ?
        "Live: both contestants are Pending. Inspect their CPU warnings below, then release one slot." :
        active.length ? "Live workloads: " + active.join(", ") + ". Use Purge Workloads before switching stages." :
        demoState?.success ? "No active lab workloads. Start with Normal Placement or Prepare Pending Pods." :
        "Live experiment state unavailable.";
}

// 2. Microservice Pods & Visual Topology
async function fetchPods() {
    try {
        const res = await fetch("/api/pods");
        const data = await res.json();
        const tbody = document.getElementById("podsTableBody");
        const matrixGrid = document.getElementById("podMatrixGrid");
        demoState = data;
        cachedPods = data.pods || [];
        updateDemoControls();
        const archived = cachedPods.filter(p => p.archived);
        const archivedList = document.getElementById("archivedVictims");
        document.getElementById("archivedVictimsPanel").hidden = archived.length === 0;
        archivedList.replaceChildren();
        for (const victim of archived) {
            const item = document.createElement("li");
            item.textContent = victim.name + " · " + victim.priority_class + " · " + victim.node + " · UID " + victim.uid;
            archivedList.appendChild(item);
        }

        if (!data.success || !data.pods || data.pods.length === 0) {
            cachedPods = [];
            tbody.innerHTML = `<tr><td colspan="10" class="empty-table-cell">${data.error ? escapeHtml(data.error) : "No Pods currently deployed in priority-scheduling."}</td></tr>`;
            matrixGrid.innerHTML = `
                <div class="empty-matrix-brutal">
                    <div class="empty-stamp">[EMPTY WORKLOAD QUEUE]</div>
                    <h3>${data.error ? "Pod data unavailable" : "No Pods currently running in priority-scheduling"}</h3>
                    <p>Use the demonstration controls above to deploy BusyBox Pods.</p>
                </div>
            `;
            updateKPIs(0, 0, 0, 0, 0);
            updateCharts([0, 0, 0], [], [], []);
            return;
        }

        const pods = data.pods;
        cachedPods = pods;

        const total = pods.filter(p => !p.archived).length;
        let highCount = 0, medCount = 0, lowCount = 0, preemptedCount = 0;
        let latencyLabels = [];
        let latencyValues = [];
        let latencyColors = [];

        tbody.innerHTML = total ? "" : '<tr><td colspan="10" class="empty-table-cell">No live Pods. Saved victims are shown below.</td></tr>';

        pods.forEach(p => {
            const isPreempted = p.preempted;
            if (isPreempted) preemptedCount++;
            if (p.archived) return;

            let barColor = "#FFE600";
            if (p.priority_class.endsWith("high-priority")) {
                if (!p.archived) highCount++;
                barColor = "#FF3366";
            } else if (p.priority_class === "medium-priority") {
                if (!p.archived) medCount++;
                barColor = "#00D2FF";
            } else if (p.priority_class.endsWith("low-priority")) {
                if (!p.archived) lowCount++;
                barColor = "#FFE600";
            }

            if (p.latency_sec !== "N/A") {
                latencyLabels.push(p.name);
                latencyValues.push(p.latency_sec);
                latencyColors.push(barColor);
            }

            // Render Table Row
            const tr = document.createElement("tr");
            const rowHighlight = isPreempted ? 'style="background: #FFE4E6; font-weight: 800; border-left: 6px solid #FF3366;"' : '';
            tr.innerHTML = `
                <td ${rowHighlight}><strong>${escapeHtml(p.name)}</strong></td>
                <td ${rowHighlight}>${getPriorityBadge(p.priority_class)}</td>
                <td ${rowHighlight}><code>${p.priority_value}</code></td>
                <td ${rowHighlight}>${getStatusBadge(isPreempted ? `${p.status} · Preempted` : p.status)}${p.scheduling_reason ? `<div class="pod-reason">${escapeHtml(p.scheduling_reason)}</div>` : ""}</td>
                <td ${rowHighlight}><small>${escapeHtml(p.assigned_node || p.node)}</small>
                    ${placementDetails(p)}</td>
                <td ${rowHighlight}><code>${escapeHtml(p.cpu_request)}</code></td>
                <td ${rowHighlight}><code>${escapeHtml(p.memory_request)}</code></td>
                <td ${rowHighlight}><small>${formatTime(p.created_at)}</small></td>
                <td ${rowHighlight}><small>${formatTime(p.scheduled_at)}</small></td>
                <td ${rowHighlight}><strong>${p.latency_sec !== "N/A" ? p.latency_sec + "s" : "--"}</strong></td>
            `;
            tbody.appendChild(tr);
        });

        updateKPIs(total, highCount, medCount, lowCount, preemptedCount);
        updateCharts([highCount, medCount, lowCount], latencyLabels, latencyValues, latencyColors);
        renderMatrix();

    } catch (err) {
        console.error("Pods fetch error:", err);
    }
}

// Render Visual Pod Cards Matrix
function renderMatrix() {
    const matrixGrid = document.getElementById("podMatrixGrid");
    if (!cachedPods || cachedPods.length === 0) return;

    let filtered = cachedPods.filter(p => !p.archived);
    if (currentFilter === "high-priority") {
        filtered = filtered.filter(p => p.priority_class.endsWith("high-priority"));
    } else if (currentFilter === "medium-priority") {
        filtered = filtered.filter(p => p.priority_class === "medium-priority");
    } else if (currentFilter === "low-priority") {
        filtered = filtered.filter(p => p.priority_class.endsWith("low-priority"));
    } else if (currentFilter === "preempted") {
        filtered = cachedPods.filter(p => p.preempted);
    }

    if (filtered.length === 0) {
        matrixGrid.innerHTML = `
            <div class="empty-matrix-brutal">
                <div class="empty-stamp">[ZERO MATCHES]</div>
                <h3>No workloads match filter '<strong>${escapeHtml(currentFilter)}</strong>'</h3>
            </div>
        `;
        return;
    }

    matrixGrid.innerHTML = "";
    filtered.forEach(p => {
        const isPreempted = p.preempted;
        const isRunning = p.status === "Running";
        const iconSvg = getServiceIconSvg(p.name);

        let statusClass = "pending";
        if (isPreempted) statusClass = "terminating";
        else if (isRunning) statusClass = "running";

        let priorityCardClass = "card-low";
        let priorityModifier = "low";
        if (p.priority_class.endsWith("high-priority")) {
            priorityCardClass = "card-high";
            priorityModifier = "high";
        } else if (p.priority_class === "medium-priority") {
            priorityCardClass = "card-medium";
            priorityModifier = "medium";
        }

        const card = document.createElement("div");
        card.className = `pod-card ${priorityCardClass}`;
        if (isPreempted) {
            card.style.borderColor = "#FF3366";
            card.style.background = "#FFF1F2";
        }

        card.innerHTML = `
            <div class="pod-card-header">
                <div class="pod-service-title">
                    <span class="pod-service-svg">${iconSvg}</span>
                    <span class="pod-name">${escapeHtml(p.name)}</span>
                </div>
                <span class="pod-status-badge ${statusClass}">
                    ${isPreempted ? 'PREEMPTED' : escapeHtml(p.status.toUpperCase())}
                </span>
            </div>
            <div class="pod-meta-tags">
                <span class="tag-priority ${priorityModifier}">${escapeHtml(p.priority_class.replace('-priority', '').toUpperCase())} [${p.priority_value}]</span>
                <span class="tag-resource">CPU: ${escapeHtml(p.cpu_request)}</span>
                <span class="tag-resource">RAM: ${escapeHtml(p.memory_request)}</span>
            </div>
            <div class="pod-footer-meta">
                <span>NODE: ${escapeHtml(p.node)}</span>
                <span>LATENCY: ${p.latency_sec !== 'N/A' ? p.latency_sec + 's' : '--'}</span>
            </div>
        `;
        matrixGrid.appendChild(card);
    });
}

function setFilter(filter, btn) {
    currentFilter = filter;
    document.querySelectorAll(".filter-tab").forEach(b => b.classList.remove("active"));
    if (btn) btn.classList.add("active");
    renderMatrix();
}

// Clean Vector Icons (No Emojis)
function getServiceIconSvg(name) {
    const n = name.toLowerCase();

    // Payment / Billing -> Credit Card
    if (n.includes("pay") || n.includes("bill")) {
        return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="1" y="4" width="22" height="16" rx="2" ry="2"></rect><line x1="1" y1="10" x2="23" y2="10"></line></svg>`;
    }
    // Auth / Security -> Lock
    if (n.includes("auth") || n.includes("sec")) {
        return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg>`;
    }
    // Orders / Fulfillment -> Package Box
    if (n.includes("order") || n.includes("fulfill")) {
        return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="m7.5 4.27 9 5.15M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z"></path><path d="m3.3 7 8.7 5 8.7-5M12 22V12"></path></svg>`;
    }
    // Telemetry / Monitoring -> Pulse Activity
    if (n.includes("telemetry") || n.includes("engine") || n.includes("monitor")) {
        return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"></polyline></svg>`;
    }
    // Frontend / Web UI -> Globe
    if (n.includes("front") || n.includes("ui") || n.includes("web") || n.includes("portal")) {
        return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="12" r="10"></circle><line x1="2" y1="12" x2="22" y2="12"></line><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"></path></svg>`;
    }
    // Inventory / Store -> Database Layers
    if (n.includes("inventory") || n.includes("store")) {
        return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><ellipse cx="12" cy="5" rx="9" ry="3"></ellipse><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"></path><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"></path></svg>`;
    }
    // Notification / Mail -> Bell
    if (n.includes("notify") || n.includes("mail")) {
        return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"></path><path d="M13.73 21a2 2 0 0 1-3.46 0"></path></svg>`;
    }
    // Analytics / ETL -> Bar Chart
    if (n.includes("analytics") || n.includes("etl")) {
        return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="18" y1="20" x2="18" y2="10"></line><line x1="12" y1="20" x2="12" y2="4"></line><line x1="6" y1="20" x2="6" y2="14"></line></svg>`;
    }
    // Video Transcoder -> Film / Video
    if (n.includes("video") || n.includes("transcod")) {
        return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polygon points="23 7 16 12 23 17 23 7"></polygon><rect x="1" y="5" width="15" height="14" rx="2" ry="2"></rect></svg>`;
    }
    // Backup / DB -> Hard Drive
    if (n.includes("backup") || n.includes("db")) {
        return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="22" y1="12" x2="2" y2="12"></line><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"></path><line x1="6" y1="16" x2="6.01" y2="16"></line><line x1="10" y1="16" x2="10.01" y2="16"></line></svg>`;
    }
    // Surge / Preemptor -> Lightning Bolt
    if (n.includes("surge") || n.includes("preemptor")) {
        return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon></svg>`;
    }
    // Victim -> Target Crosshair
    if (n.includes("victim")) {
        return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="12" r="10"></circle><line x1="22" y1="12" x2="18" y2="12"></line><line x1="6" y1="12" x2="2" y2="12"></line><line x1="12" y1="6" x2="12" y2="2"></line><line x1="12" y1="22" x2="12" y2="18"></line></svg>`;
    }
    // Default -> CPU Microchip
    return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="4" y="4" width="16" height="16" rx="2"></rect><rect x="9" y="9" width="6" height="6"></rect><line x1="9" y1="1" x2="9" y2="4"></line><line x1="15" y1="1" x2="15" y2="4"></line><line x1="9" y1="20" x2="9" y2="23"></line><line x1="15" y1="20" x2="15" y2="23"></line><line x1="20" y1="9" x2="23" y2="9"></line><line x1="20" y1="14" x2="23" y2="14"></line><line x1="1" y1="9" x2="4" y2="9"></line><line x1="1" y1="14" x2="4" y2="14"></line></svg>`;
}

// 3. Kubernetes Events
async function fetchEvents() {
    try {
        const res = await fetch("/api/events");
        const data = await res.json();
        const tbody = document.getElementById("eventsTableBody");

        if (data.error || !data.events || data.events.length === 0) {
            tbody.innerHTML = `<tr><td colspan="5" class="empty-table-cell">${escapeHtml(data.error || "No scheduling events recorded yet.")}</td></tr>`;
            return;
        }

        tbody.innerHTML = "";
        const namespaceEvents = data.events.filter(event => !event.archived);
        const recent = namespaceEvents.slice(-15);
        const evidence = namespaceEvents.slice(0, -15).filter(ev => ev.preemption || ev.reason === "FailedScheduling");
        [...recent, ...evidence.slice(-10)].sort((a, b) => b.created_at.localeCompare(a.created_at)).forEach(ev => {
            const tr = document.createElement("tr");
            const isPreempt = ev.preemption;
            const rowClass = isPreempt ? 'style="background: #FFE4E6; border-left: 6px solid #FF3366; font-weight: 800;"' : '';

            tr.innerHTML = `
                <td ${rowClass}><small>${formatTime(ev.timestamp)}</small></td>
                <td ${rowClass}><span class="pod-status-badge ${ev.type === 'Warning' ? 'terminating' : 'running'}">${ev.type.toUpperCase()}</span></td>
                <td ${rowClass}><strong>${escapeHtml(ev.reason)}</strong></td>
                <td ${rowClass}><code>${escapeHtml(ev.object)}</code></td>
                <td ${rowClass}>${escapeHtml(ev.message)}${ev.archived ? " (saved)" : ""}</td>
            `;
            tbody.appendChild(tr);
        });
    } catch (err) {
        console.error("Events fetch error:", err);
    }
}

function updateKPIs(total, high, med, low, preempted) {
    document.getElementById("valTotalPods").textContent = total;
    document.getElementById("valHighPods").textContent = high;
    document.getElementById("valMedPods").textContent = med;
    document.getElementById("valLowPods").textContent = low;
    document.getElementById("valPreemptedPods").textContent = preempted;
}

function updateCharts(priorityCounts, labels, latencies, colors) {
    if (priorityChart) {
        priorityChart.data.datasets[0].data = priorityCounts;
        priorityChart.update();
    }
    if (latencyChart) {
        latencyChart.data.labels = labels;
        latencyChart.data.datasets[0].data = latencies;
        latencyChart.data.datasets[0].backgroundColor = colors;
        latencyChart.update();
    }
}

// Trigger Backend Actions
async function triggerAction(actionName, label) {
    const consoleBox = document.getElementById("consoleOutput");
    consoleBox.textContent = `[EXECUTING ACTION] >>> ${label}\nInvoking PowerShell automation script...\nVerifying the active kind context for priority-scheduling...\nPlease standby...\n`;

    actionRunning = true;
    updateDemoControls();

    try {
        const res = await fetch(`/api/action/${actionName}`, { method: "POST" });
        const result = await res.json();

        const status = result.stage || result.status || (result.success ? "PASS" : "FAIL");
        const report = [result.stdout, result.stderr || result.error].filter(Boolean).join("\n");
        consoleBox.textContent = `[${status}] ${label}\n\n` + report;
    } catch (err) {
        consoleBox.textContent = `[COMMUNICATION FAULT] Failed to communicate with Flask backend: ${err.message}`;
    } finally {
        actionRunning = false;
        await Promise.all([fetchPods(), fetchPreemptionAudit()]);
        refreshAll();
    }
}

function exportCsv() {
    window.location.href = "/api/export-csv";
}

function clearConsole() {
    document.getElementById("consoleOutput").textContent = "Terminal buffer reset. Ready for operator commands.";
}

function toggleAutoRefresh(enabled) {
    if (autoRefreshInterval) {
        clearInterval(autoRefreshInterval);
        autoRefreshInterval = null;
    }
    if (enabled) {
        autoRefreshInterval = setInterval(() => {
            refreshAll();
        }, 4000);
    }
}

function getPriorityBadge(pClass) {
    const tier = {
        "high-priority": "high", "order-high-priority": "high", "medium-priority": "medium",
        "low-priority": "low", "order-low-priority": "low"
    }[pClass] || "";
    return '<span class="tag-priority ' + tier + '">' + escapeHtml(pClass) + '</span>';
}

function getStatusBadge(status) {
    if (status === "Running") {
        return `<span class="pod-status-badge running">RUNNING</span>`;
    } else if (status === "Pending") {
        return `<span class="pod-status-badge pending">PENDING</span>`;
    } else if (status.includes("Terminating") || status.includes("Preempted")) {
        return `<span class="pod-status-badge terminating">${escapeHtml(status.toUpperCase())}</span>`;
    }
    return `<span class="pod-status-badge pending">${escapeHtml(status.toUpperCase())}</span>`;
}

function formatTime(isoStr) {
    if (!isoStr || isoStr === "N/A") return "--";
    try {
        const d = new Date(isoStr);
        return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    } catch {
        return isoStr;
    }
}

function escapeHtml(str) {
    if (!str) return "";
    return String(str)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#039;");
}
