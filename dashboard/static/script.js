/* ==============================================================================
   KUBEPRIORITY // VIBRANT NEOBRUTALISM CONTROLLER & REAL-TIME TELEMETRY
   VECTOR ICON ENGINE (NO EMOJIS - STRICT SVG & SYMBOLS)
   ============================================================================== */

let autoRefreshInterval = null;
let priorityChart = null;
let latencyChart = null;
let currentFilter = "all";
let cachedPods = [];

document.addEventListener("DOMContentLoaded", () => {
    initCharts();
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

function refreshAll() {
    fetchStatus();
    fetchPods();
    fetchEvents();
}

// 1. Cluster Status & Hardware Telemetry
async function fetchStatus() {
    try {
        const res = await fetch("/api/status");
        const data = await res.json();
        const dot = document.getElementById("statusDot");
        const title = document.getElementById("clusterStatusText");
        const nodeInfo = document.getElementById("clusterNodeInfo");

        if (data.connected) {
            dot.className = "status-indicator online";
            title.textContent = "CLUSTER: ONLINE";
            title.style.color = "#000000";

            if (data.nodes && data.nodes.length > 0) {
                const n = data.nodes[0];
                nodeInfo.textContent = `NODE: ${n.name.toUpperCase()} (${n.allocatable_cpu} CORES)`;
                document.getElementById("hwNodeBadge").textContent = `NODE: ${n.name.toUpperCase()} (${n.allocatable_cpu} CORES)`;
            }

            if (data.resources) {
                const r = data.resources;
                document.getElementById("cpuGaugeText").textContent = `${r.committed_cpu_milli}m / ${r.total_cpu_milli}m (${r.cpu_percentage}%)`;
                document.getElementById("cpuProgressBar").style.width = `${r.cpu_percentage}%`;
                document.getElementById("cpuHintText").textContent = `Allocated capacity committed to running & scheduled workloads`;

                document.getElementById("memGaugeText").textContent = `${r.allocatable_memory}`;
            }
        } else {
            dot.className = "status-indicator offline";
            title.textContent = "CLUSTER: OFFLINE";
            title.style.color = "#FF2A4B";
            nodeInfo.textContent = "MINIKUBE STOPPED";
        }
    } catch (err) {
        console.error("Status fetch error:", err);
    }
}

// 2. Microservice Pods & Visual Topology
async function fetchPods() {
    try {
        const res = await fetch("/api/pods");
        const data = await res.json();
        const tbody = document.getElementById("podsTableBody");
        const matrixGrid = document.getElementById("podMatrixGrid");

        if (!data.success || !data.pods || data.pods.length === 0) {
            cachedPods = [];
            tbody.innerHTML = `<tr><td colspan="10" class="empty-table-cell">No microservices currently deployed in <code>priority-scheduling</code>.</td></tr>`;
            matrixGrid.innerHTML = `
                <div class="empty-matrix-brutal">
                    <div class="empty-stamp">[EMPTY WORKLOAD QUEUE]</div>
                    <h3>No microservices currently running in <code>priority-scheduling</code></h3>
                    <p>Click <strong>RUN EXPERIMENT 1</strong> (12 Pods) or <strong>RUN EXPERIMENT 2</strong> (Preemption Surge) above to deploy real workloads.</p>
                </div>
            `;
            updateKPIs(0, 0, 0, 0, 0);
            updateCharts([0, 0, 0], [], [], []);
            return;
        }

        const pods = data.pods;
        cachedPods = pods;

        let total = pods.length;
        let highCount = 0, medCount = 0, lowCount = 0, preemptedCount = 0;
        let latencyLabels = [];
        let latencyValues = [];
        let latencyColors = [];

        tbody.innerHTML = "";

        pods.forEach(p => {
            const isPreempted = p.status.includes("Terminating");
            if (isPreempted) preemptedCount++;

            let barColor = "#FFE600";
            if (p.priority_class === "high-priority") {
                highCount++;
                barColor = "#FF3366";
            } else if (p.priority_class === "medium-priority") {
                medCount++;
                barColor = "#00D2FF";
            } else if (p.priority_class === "low-priority") {
                lowCount++;
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
                <td ${rowHighlight}>${getPriorityBadge(p.priority_class, p.priority_value)}</td>
                <td ${rowHighlight}><code>${p.priority_value}</code></td>
                <td ${rowHighlight}>${getStatusBadge(p.status)}</td>
                <td ${rowHighlight}><small>${escapeHtml(p.node)}</small></td>
                <td ${rowHighlight}><code>${p.cpu_request}</code></td>
                <td ${rowHighlight}><code>${p.memory_request}</code></td>
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

    let filtered = cachedPods;
    if (currentFilter === "high-priority") {
        filtered = cachedPods.filter(p => p.priority_class === "high-priority");
    } else if (currentFilter === "medium-priority") {
        filtered = cachedPods.filter(p => p.priority_class === "medium-priority");
    } else if (currentFilter === "low-priority") {
        filtered = cachedPods.filter(p => p.priority_class === "low-priority");
    } else if (currentFilter === "terminating") {
        filtered = cachedPods.filter(p => p.status.includes("Terminating"));
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
        const isPreempted = p.status.includes("Terminating");
        const isRunning = p.status === "Running";
        const iconSvg = getServiceIconSvg(p.name);

        let statusClass = "pending";
        if (isPreempted) statusClass = "terminating";
        else if (isRunning) statusClass = "running";

        let priorityCardClass = "card-low";
        let priorityModifier = "low";
        if (p.priority_class === "high-priority") {
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
                    ${isPreempted ? 'PREEMPTED' : p.status.toUpperCase()}
                </span>
            </div>
            <div class="pod-meta-tags">
                <span class="tag-priority ${priorityModifier}">${p.priority_class.replace('-priority', '').toUpperCase()} [${p.priority_value}]</span>
                <span class="tag-resource">CPU: ${p.cpu_request}</span>
                <span class="tag-resource">RAM: ${p.memory_request}</span>
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

        if (!data.events || data.events.length === 0) {
            tbody.innerHTML = `<tr><td colspan="5" class="empty-table-cell">No scheduling events recorded yet.</td></tr>`;
            return;
        }

        tbody.innerHTML = "";
        data.events.slice(-15).reverse().forEach(ev => {
            const tr = document.createElement("tr");
            const isPreempt = ev.reason === "Preempted" || ev.message.toLowerCase().includes("preempt");
            const rowClass = isPreempt ? 'style="background: #FFE4E6; border-left: 6px solid #FF3366; font-weight: 800;"' : '';

            tr.innerHTML = `
                <td ${rowClass}><small>${formatTime(ev.timestamp)}</small></td>
                <td ${rowClass}><span class="pod-status-badge ${ev.type === 'Warning' ? 'terminating' : 'running'}">${ev.type.toUpperCase()}</span></td>
                <td ${rowClass}><strong>${escapeHtml(ev.reason)}</strong></td>
                <td ${rowClass}><code>${escapeHtml(ev.object)}</code></td>
                <td ${rowClass}>${escapeHtml(ev.message)}</td>
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
    if (latencyChart && labels.length > 0) {
        latencyChart.data.labels = labels;
        latencyChart.data.datasets[0].data = latencies;
        latencyChart.data.datasets[0].backgroundColor = colors;
        latencyChart.update();
    }
}

// Trigger Backend Actions
async function triggerAction(actionName, label) {
    const consoleBox = document.getElementById("consoleOutput");
    consoleBox.textContent = `[EXECUTING ACTION] >>> ${label}\nInvoking PowerShell automation script...\nTargeting cluster context 'minikube' / namespace 'priority-scheduling'...\nPlease standby...\n`;

    const buttons = document.querySelectorAll(".btn-brutal");
    buttons.forEach(b => b.disabled = true);

    try {
        const res = await fetch(`/api/action/${actionName}`, { method: "POST" });
        const result = await res.json();

        if (result.success) {
            consoleBox.textContent = `[SUCCESS // EXIT CODE 0] >>> ${label} COMPLETED:\n\n` + result.stdout;
        } else {
            consoleBox.textContent = `[ERROR // EXIT CODE ${result.exit_code}] >>> ${label} FAILED:\n\n` + 
                (result.stdout ? result.stdout + "\n" : "") + 
                (result.stderr ? result.stderr : (result.error || "Unknown execution fault"));
        }
    } catch (err) {
        consoleBox.textContent = `[COMMUNICATION FAULT] Failed to communicate with Flask backend: ${err.message}`;
    } finally {
        buttons.forEach(b => b.disabled = false);
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

function getPriorityBadge(pClass, pValue) {
    if (pClass === "high-priority") {
        return `<span class="tag-priority high">HIGH [${pValue}]</span>`;
    } else if (pClass === "medium-priority") {
        return `<span class="tag-priority medium">MED [${pValue}]</span>`;
    } else if (pClass === "low-priority") {
        return `<span class="tag-priority low">LOW [${pValue}]</span>`;
    }
    return `<span class="tag-priority low">${escapeHtml(pClass)}</span>`;
}

function getStatusBadge(status) {
    if (status === "Running") {
        return `<span class="pod-status-badge running">RUNNING</span>`;
    } else if (status === "Pending") {
        return `<span class="pod-status-badge pending">PENDING</span>`;
    } else if (status.includes("Terminating")) {
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
