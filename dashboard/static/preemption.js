const auditStageNames = {
    Prepare: "3A · Prepare Workloads", Equal: "3B · Test Equal Priority",
    Preempt: "3C · Trigger Preemption", Compare: "3D · Compare Results"
};
const auditFilterIds = {stage: "auditStage", node: "auditNode", workload: "auditWorkload", reason: "auditReason"};
let auditData = null;
let auditRequest = 0;
let auditRendered = "";
let auditEventsRendered = "";

function auditById(id) {
    return document.getElementById(id);
}

function updatePreemptionControls(blocked) {
    const allowed = auditData?.current ? auditData.controls : {};
    for (const [button, stage] of Object.entries({
        btnExp2: "prepare", btnEqual: "equal", btnPreempt: "preempt", btnCompare: "compare"
    })) {
        auditById(button).disabled = blocked || !allowed[stage];
    }
}

function placementDetails(pod) {
    const selector = Object.entries(pod.node_selector || {}).map(([key, value]) => key + "=" + value).join(", ");
    const affinity = Object.keys(pod.affinity || {}).length ? JSON.stringify(pod.affinity, null, 2) : "";
    const constraints = selector || affinity ? [
        selector ? "Node selector: " + selector : "", affinity ? "Affinity:\n" + affinity : ""
    ].filter(Boolean).join("\n") : "No selector or affinity configured.";
    return '<details class="placement-detail"><summary>Constraints and policy</summary><pre class="audit-code">' +
        escapeHtml(constraints + "\nPreemption policy: " + (pod.preemption_policy || "Unavailable")) + "</pre></details>";
}

function auditText(container, tag, text) {
    const node = document.createElement(tag);
    node.textContent = text;
    container.appendChild(node);
    return node;
}

function auditOptions(select, entries) {
    const previous = select.value;
    if (JSON.stringify(entries) === select.dataset.entries) return;
    select.dataset.entries = JSON.stringify(entries);
    select.replaceChildren();
    for (const [value, text] of entries) select.add(new Option(text, value));
    if (entries.some(([value]) => value === previous)) select.value = previous;
}

function auditTable(container, headers) {
    const wrapper = document.createElement("div");
    wrapper.className = "table-scroll-wrapper";
    const table = document.createElement("table");
    table.className = "nb-table audit-table";
    const heading = table.createTHead().insertRow();
    for (const title of headers) auditText(heading, "th", title);
    wrapper.appendChild(table);
    container.appendChild(wrapper);
    return table.createTBody();
}

function showAuditWorkloads(container, title, workloads, run) {
    if (!workloads.length) return;
    auditText(container, "h3", title);
    const table = auditTable(container, [
        "WORKLOAD / POD UID", "STATE", "PRIORITY / POLICY", "CPU / RAM REQUESTED",
        "ACTUAL ASSIGNMENT / LAST SEEN", "CONFIGURED PLACEMENT", "MANIFEST"
    ]);
    for (const pod of workloads) {
        const row = table.insertRow();
        const identity = row.insertCell();
        auditText(identity, "strong", pod.name);
        auditText(identity, "small", pod.uid).className = "audit-uid";
        row.insertCell().textContent = pod.classification ? pod.classification + " · " + pod.status : pod.status;
        row.insertCell().textContent = pod.priority_class + " (" + pod.priority_value + ") / " +
            (pod.preemption_policy || "Unavailable");
        row.insertCell().textContent = pod.cpu_request + " / " + pod.memory_request;
        row.insertCell().textContent = pod.assigned_node || "Unassigned";
        const placement = row.insertCell();
        const selector = Object.entries(pod.node_selector || {}).map(([key, value]) => key + "=" + value).join(", ");
        placement.textContent = selector || (Object.keys(pod.affinity || {}).length ? "Affinity configured" : "None");
        if (Object.keys(pod.affinity || {}).length) {
            const details = document.createElement("details");
            auditText(details, "summary", "Affinity");
            auditText(details, "pre", JSON.stringify(pod.affinity, null, 2)).className = "audit-code";
            placement.appendChild(details);
        }
        const button = auditText(row.insertCell(), "button", "Inspect YAML");
        button.className = "filter-tab";
        button.type = "button";
        button.addEventListener("click", () => inspectPodYaml(run, pod.name));
    }
}

function showAuditResources(container, workers, comparison) {
    if (!workers?.some(worker => worker.before)) return;
    auditText(container, "h3", comparison ? "CPU before and after" : "Saved baseline CPU");
    const titles = ["WORKER", "ALLOCATABLE BEFORE", "COMMITTED BEFORE", "AVAILABLE BEFORE", "INCOMING REQUEST"];
    if (comparison) titles.push("RELEASED BY CONFIRMED VICTIMS", "ALLOCATABLE AFTER", "COMMITTED AFTER", "AVAILABLE AFTER");
    const table = auditTable(container, titles);
    const cpu = number => number == null ? "Unobserved" : number + "m";
    for (const worker of workers) {
        if (!worker.before) continue;
        const row = table.insertRow();
        const cells = [worker.node, cpu(worker.before.allocatableCpuMilli), cpu(worker.before.requestedCpuMilli),
            cpu(worker.before.freeCpuMilli), cpu(worker.highCpuMilli)];
        if (comparison) {
            cells.push((worker.releasedVictims || []).map(victim =>
                victim.name + ": " + cpu(victim.cpuMilli) + " / " + formatMemory(victim.memoryBytes)).join("\n") ||
                "No verified release", cpu(worker.after?.allocatableCpuMilli), cpu(worker.after?.requestedCpuMilli),
                cpu(worker.after?.freeCpuMilli));
        }
        for (const text of cells) row.insertCell().textContent = text;
    }
    auditText(container, "p", "Available CPU = allocatable CPU − committed CPU requests. Released requests use the victims’ saved Pod specifications.");
}

function renderPreemptionOverview(data) {
    const overview = auditById("auditOverview");
    const comparison = auditById("auditComparison");
    const workflow = auditById("auditWorkflow");
    overview.replaceChildren();
    comparison.replaceChildren();
    workflow.replaceChildren();
    if (!data.run_id) return;
    for (const step of data.steps || []) {
        auditText(workflow, "li", auditStageNames[step.stage] + " · started " + step.started_at +
            (step.finished_at ? " · recorded " + step.finished_at : " · waiting for final evidence"));
    }
    for (const failure of data.failures || []) {
        auditText(workflow, "li", auditStageNames[failure.stage] + " · " + failure.evidence.verdict +
            " · " + failure.evidence.message);
    }
    const prepared = data.prepared;
    if (prepared && !data.comparison) showAuditResources(overview, prepared.workers, false);
    const equal = data.equal?.comparison;
    if (equal) {
        auditText(overview, "h3", "Equal-priority result");
        auditText(overview, "p", equal.equalPod + " (" + equal.equalPriority + ") was observed " + equal.equalPhase +
            ". It requested " + equal.incomingCpuMilli + "m CPU and " + equal.incomingMemory +
            " with " + equal.freeCpuMilli + "m CPU free on " + equal.node + ".");
        auditText(overview, "p", equal.failure);
        const manifest = auditText(overview, "button", "Inspect equal-probe YAML");
        manifest.type = "button";
        manifest.className = "filter-tab";
        manifest.addEventListener("click", () => inspectPodYaml(data.run_id, equal.equalPod));
    }
    if (data.comparison) {
        const result = data.comparison;
        auditText(comparison, "h3", result.verdict + " · Before-and-after comparison");
        auditText(comparison, "p", result.message);
        showAuditResources(comparison, result.workers, true);
        showAuditWorkloads(comparison, "Before · original workloads", result.before, data.run_id);
        showAuditWorkloads(comparison, "After · surviving, preempted and incoming workloads", result.after, data.run_id);
    } else {
        showAuditWorkloads(overview, data.current ? "Workloads · live and captured states" : "Saved workload states",
            data.workloads || [], data.run_id);
    }
}

function renderPreemptionEvents(events) {
    const tbody = auditById("auditEventRows");
    tbody.replaceChildren();
    if (!events.length) {
        const cell = tbody.insertRow().insertCell();
        cell.colSpan = 4;
        cell.className = "empty-table-cell";
        cell.textContent = "No event evidence for this selection.";
    }
    for (const event of events) {
        const row = tbody.insertRow();
        const time = row.insertCell();
        auditText(time, "code", event.timestamp || "First time unavailable");
        if (event.last_observed && event.last_observed !== event.timestamp) {
            auditText(time, "small", "Last: " + event.last_observed).className = "audit-uid";
        }
        row.insertCell().textContent = auditStageNames[event.stage] || "Stage unavailable";
        const workload = row.insertCell();
        auditText(workload, "strong", event.workload);
        auditText(workload, "small", event.pod_uid || "Pod UID unavailable").className = "audit-uid";
        auditText(workload, "small", event.node ? event.node + " (" + event.node_basis + ")" : "Node unavailable");
        const message = row.insertCell();
        auditText(message, "strong", event.reason + " · " + event.origin +
            (event.occurrences > 1 ? " · " + event.occurrences + " occurrences" : ""));
        auditText(message, "p", event.message);
        if (event.raw) {
            const details = document.createElement("details");
            auditText(details, "summary", "Raw Kubernetes event");
            auditText(details, "pre", JSON.stringify(event.raw, null, 2)).className = "audit-code";
            message.appendChild(details);
        }
    }
}

async function fetchPreemptionAudit() {
    const id = ++auditRequest;
    const params = new URLSearchParams({run: auditById("auditRun").value || "current", order: auditById("auditOrder").value});
    for (const [field, control] of Object.entries(auditFilterIds)) {
        if (auditById(control).value) params.set(field, auditById(control).value);
    }
    try {
        const response = await fetch("/api/preemption?" + params);
        const data = await response.json();
        if (id !== auditRequest) return;
        if (!response.ok) throw new Error(data.error || "Unable to read audit evidence.");
        auditData = data;
        auditOptions(auditById("auditRun"), [["current", "Current run"], ...data.saved_runs.map(run => [run, "Saved · " + run])]);
        for (const [field, control] of Object.entries(auditFilterIds)) {
            auditOptions(auditById(control), [["", "All"], ...(data.facets?.[field] ?? []).map(value =>
                [value, field === "stage" ? auditStageNames[value] : value])]);
        }
        auditById("auditState").textContent = data.run_id ?
            (data.current ? "Current run" : "Saved run") + " · " + data.run_id + " · " + data.phase :
            data.phase === "Needs reset" ? "Existing workloads have no matching staged run. Purge them before preparing." :
                "No active Experiment 3 run. Choose Prepare Workloads or select a saved run.";
        const overview = JSON.stringify([data.run_id, data.steps, data.prepared, data.equal, data.workloads, data.comparison, data.failures]);
        if (overview !== auditRendered) {
            auditRendered = overview;
            renderPreemptionOverview(data);
        }
        const events = JSON.stringify(data.events);
        if (events !== auditEventsRendered) {
            auditEventsRendered = events;
            renderPreemptionEvents(data.events);
        }
    } catch (error) {
        if (id !== auditRequest) return;
        auditData = null;
        auditById("auditState").textContent = error.message;
        auditRendered = auditEventsRendered = "";
        renderPreemptionOverview({});
        renderPreemptionEvents([]);
    } finally {
        if (id === auditRequest) updateDemoControls();
    }
}

async function inspectPodYaml(run, pod) {
    const panel = auditById("manifestPanel");
    panel.hidden = false;
    panel.open = true;
    auditById("manifestTitle").textContent = "Saved manifest · " + pod + " · " + run;
    const content = auditById("manifestContent");
    content.textContent = "Loading…";
    panel.scrollIntoView({block: "nearest"});
    try {
        const response = await fetch("/api/preemption/manifest/" + encodeURIComponent(run) + "/" + encodeURIComponent(pod));
        content.textContent = response.ok ? await response.text() : "This run has no saved manifest for the selected workload.";
    } catch (error) {
        content.textContent = error.message;
    }
}

async function openPreemptionComparison() {
    await triggerAction("compare-preemption", "3D — Compare Results");
    if (auditData?.comparison) {
        auditById("auditComparison").focus();
        auditById("auditComparison").scrollIntoView({block: "start"});
    }
}

document.addEventListener("DOMContentLoaded", () => {
    auditById("auditRun").addEventListener("change", () => {
        for (const control of Object.values(auditFilterIds)) auditById(control).value = "";
        auditById("manifestPanel").hidden = true;
        fetchPreemptionAudit();
    });
    for (const control of [...Object.values(auditFilterIds), "auditOrder"]) {
        auditById(control).addEventListener("change", fetchPreemptionAudit);
    }
});
