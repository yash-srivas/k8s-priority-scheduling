import csv
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from decimal import Decimal, ROUND_CEILING
from pathlib import Path
from urllib.parse import urlsplit

from flask import Flask, g, jsonify, render_template, request, send_from_directory

app = Flask(__name__)
app.config["TEMPLATES_AUTO_RELOAD"] = True
app.config["SEND_FILE_MAX_AGE_DEFAULT"] = 0

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = PROJECT_ROOT / "scripts"
RESULTS_DIR = PROJECT_ROOT / "results" / "kind"
NAMESPACE = "priority-scheduling"
CONTROL_ROLES = {"node-role.kubernetes.io/control-plane", "node-role.kubernetes.io/master"}
CONTEXT_PATTERN = re.compile(r"kind-([a-z0-9][a-z0-9-]*)")
RUN_PATTERN = re.compile(r"\d{8}-\d{6}-\d{7}-[a-f0-9]{8}")
POD_NAME_PATTERN = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
ACTIONS = {
    "run-experiment-1": "run-experiment-1.ps1",
    "run-experiment-2": "run-experiment-2.ps1",
    "prepare-preemption": "run-experiment-2.ps1",
    "test-equal-priority": "run-experiment-2.ps1",
    "trigger-preemption": "run-experiment-2.ps1",
    "compare-preemption": "run-experiment-2.ps1",
    "prepare-scheduling-order": "run-scheduling-order.ps1",
    "release-scheduling-order": "run-scheduling-order.ps1",
    "collect-results": "collect-results.ps1",
    "cleanup": "cleanup.ps1",
    "check-env": "check-environment.ps1",
}
ACTION_STAGES = {
    "prepare-scheduling-order": "Prepare", "release-scheduling-order": "Release",
    "run-experiment-2": "Prepare", "prepare-preemption": "Prepare",
    "test-equal-priority": "Equal", "trigger-preemption": "Preempt", "compare-preemption": "Compare",
}
PRIMARY_CLASSES = {"high-priority": "high", "medium-priority": "medium", "low-priority": "low"}
EVENT_EVIDENCE = {"Scheduled", "FailedScheduling", "Preempted"}
OWNER_LABEL = "app.kubernetes.io/managed-by"
RESULT_FILES = {
    "experiment-1": "experiment-1-results.csv",
    "experiment-2": "experiment-2-results.csv",
    "scheduling-order": "scheduling-order-results.csv",
    "all": "all-pods-summary.csv",
}


class ClusterError(Exception):
    pass


def run_command(args, timeout=12):
    env = dict(os.environ, KIND_EXPERIMENTAL_PROVIDER="docker")
    try:
        proc = subprocess.run(args, capture_output=True, text=True, errors="replace",
                              timeout=timeout, cwd=PROJECT_ROOT, env=env, shell=False)
        return proc.stdout.strip(), proc.stderr.strip(), proc.returncode
    except subprocess.TimeoutExpired:
        return "", f"{args[0]} timed out after {timeout}s.", -1
    except OSError as exc:
        return "", f"Cannot start {args[0]}: {exc}", -2


def checked_command(args):
    out, err, code = run_command(args)
    if code:
        raise ClusterError(err or out or f"{args[0]} failed with exit code {code}.")
    return out


def get_lab_context():
    """Pin all reads in a request to the active Docker kind cluster."""
    if "lab_context" in g:
        return g.lab_context
    context = os.environ.get("PRIORITY_KUBECTL_CONTEXT") or checked_command(["kubectl", "config", "current-context"])
    match = CONTEXT_PATTERN.fullmatch(context)
    expected = os.environ.get("PRIORITY_KIND_CLUSTER")
    if not match or (expected and match[1] != expected):
        raise ClusterError(f"Select the intended kind cluster. Current context is {context}.")
    trusted = checked_command(["kind", "get", "kubeconfig", "--name", match[1]])
    active = checked_command(["kubectl", "--context", context, "config", "view", "--minify",
                              "--flatten", "--raw", "-o", "json"])
    cluster = json.loads(active)["clusters"][0]["cluster"]
    for key in ("server", "certificate-authority-data"):
        attribute = re.search(rf"^[ \t]+{key}: (\S+)[ \t]*$", trusted, flags=re.MULTILINE)
        if not attribute or cluster.get(key) != attribute[1]:
            raise ClusterError(f"Kubeconfig identity does not match Docker kind cluster {match[1]}.")
    if any(cluster.get(k) for k in ("insecure-skip-tls-verify", "proxy-url", "tls-server-name")):
        raise ClusterError("The kubeconfig has TLS or proxy overrides for the kind cluster.")
    g.lab_context = context
    return context


def run_kubectl(args, timeout=12):
    return run_command(["kubectl", "--context", get_lab_context(), "--request-timeout=8s", *args], timeout)


def kubectl_json(*args):
    stdout, stderr, code = run_kubectl([*args, "-o", "json"])
    if code:
        raise ClusterError(stderr or stdout)
    return json.loads(stdout)


def run_powershell_script(action_name, timeout=480):
    script_name = ACTIONS[action_name]
    command = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
               "-File", str(SCRIPTS_DIR / script_name)]
    if action_name in ACTION_STAGES:
        command.extend(["-Stage", ACTION_STAGES[action_name]])
    return run_command(command, timeout)


def parse_quantity(value):
    if not value:
        return Decimal(0)
    match = re.fullmatch(r"([+-]?(?:\d+(?:\.\d*)?|\.\d+))([eE][+-]?\d+|[numkKMGTEP]|[KMGTPE]i)?", str(value))
    if not match:
        raise ValueError(f"Unsupported Kubernetes resource quantity {value!r}.")
    magnitude, suffix = match.groups()
    if suffix and suffix.endswith("i"):
        return Decimal(magnitude) * (1024 ** ("KMGTPE".index(suffix[0]) + 1))
    exponents = {None: 0, "n": -9, "u": -6, "m": -3, "k": 3, "K": 3,
                 "M": 6, "G": 9, "T": 12, "P": 15, "E": 18}
    exponent = exponents[suffix] if suffix in exponents else int(suffix[1:])
    return Decimal(magnitude).scaleb(exponent)


def round_up(value):
    return int(value.to_integral_value(rounding=ROUND_CEILING))


def parse_cpu_milli(value):
    return round_up(parse_quantity(value) * 1000)


def pod_request(pod, resource):
    spec = pod.get("spec", {})

    def request_for(container):
        return parse_quantity(container.get("resources", {}).get("requests", {}).get(resource))

    regular = sum((request_for(container) for container in spec.get("containers", [])), Decimal(0))
    sidecars = peak = Decimal(0)
    for container in spec.get("initContainers", []):
        amount = request_for(container)
        if container.get("restartPolicy") == "Always":
            sidecars += amount
            peak = max(peak, sidecars)
        else:
            peak = max(peak, sidecars + amount)
    total = max(regular + sidecars, peak)
    pod_level = spec.get("resources", {}).get("requests", {}).get(resource)
    if pod_level is not None:
        total = parse_quantity(pod_level)
    allocated = sum(max(parse_quantity(status.get("allocatedResources", {}).get(resource)),
                        request_for(status))
                    for status in pod.get("status", {}).get("containerStatuses", []))
    return max(total, allocated) + parse_quantity(spec.get("overhead", {}).get(resource))


def node_summary(node, pods, usage):
    metadata = node["metadata"]
    name = metadata["name"]
    status = node["status"]
    control_plane = bool(CONTROL_ROLES.intersection(metadata.get("labels", {})))
    ready = any(c["type"] == "Ready" and c["status"] == "True" for c in status.get("conditions", []))
    spec = node.get("spec", {})
    blocked = spec.get("unschedulable") or any(
        taint["effect"] in ("NoSchedule", "NoExecute") for taint in spec.get("taints", []))
    capacity, allocatable = status["capacity"], status["allocatable"]
    cpu_by_tier = dict.fromkeys(("high", "medium", "low", "other"), 0)
    for pod in pods:
        priority_class = pod.get("spec", {}).get("priorityClassName", "").removeprefix("order-")
        cpu_by_tier[PRIMARY_CLASSES.get(priority_class, "other")] += round_up(pod_request(pod, "cpu") * 1000)
    requested_cpu = sum(cpu_by_tier.values())
    allocatable_cpu = parse_cpu_milli(allocatable["cpu"])
    return {
        "name": name, "role": "Control plane" if control_plane else "Worker",
        "ready": "Ready" if ready else "NotReady", "eligible_worker": ready and not control_plane and not blocked,
        "capacity_cpu": capacity["cpu"], "capacity_memory": capacity["memory"],
        "allocatable_cpu": allocatable["cpu"], "allocatable_memory": allocatable["memory"],
        "total_cpu_milli": allocatable_cpu,
        "cpu_by_tier": cpu_by_tier, "free_cpu_milli": allocatable_cpu - requested_cpu,
        "taints": spec.get("taints", []),
        "allocatable_memory_bytes": round_up(parse_quantity(allocatable["memory"])),
        "requested_cpu_milli": requested_cpu,
        "requested_memory_bytes": sum(round_up(pod_request(pod, "memory")) for pod in pods),
        "usage": usage,
    }


def node_metrics():
    stdout, stderr, code = run_kubectl(["get", "--raw", "/apis/metrics.k8s.io/v1beta1/nodes"])
    if code:
        if "notfound" in stderr.lower() or "could not find the requested resource" in stderr.lower():
            return {}, "Actual resource usage unavailable: Metrics Server API is not installed."
        return {}, "Actual resource usage unavailable: the Metrics Server API could not be queried."
    return {n["metadata"]["name"]: n["usage"] for n in json.loads(stdout).get("items", [])}, ""


@app.before_request
def require_local_dashboard():
    if urlsplit("//" + request.host).hostname not in {"127.0.0.1", "localhost", "::1"}:
        return jsonify(error="Use the local dashboard address."), 403
    if request.method == "POST":
        origin = request.headers.get("Origin")
        if (origin and origin != request.host_url.rstrip("/")) or request.headers.get("Sec-Fetch-Site") == "cross-site":
            return jsonify(success=False, error="Cross-origin actions are disabled."), 403


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/status")
def get_status():
    try:
        context = get_lab_context()
        raw_nodes = kubectl_json("get", "nodes")["items"]
        classes = kubectl_json("get", "priorityclasses")["items"]
        all_pods = kubectl_json("get", "pods", "-A")["items"]
        grouped = {}
        for pod in all_pods:
            name = pod.get("spec", {}).get("nodeName")
            if name and pod.get("status", {}).get("phase") not in {"Succeeded", "Failed"}:
                grouped.setdefault(name, []).append(pod)
        usage, metrics_message = node_metrics()
        nodes = [node_summary(node, grouped.get(node["metadata"]["name"], []),
                              usage.get(node["metadata"]["name"])) for node in raw_nodes]

        # Sum all observed node requests and allocatable resources on the same scope.
        cpu = sum(node["total_cpu_milli"] for node in nodes)
        memory = sum(node["allocatable_memory_bytes"] for node in nodes)
        requested_cpu = sum(node["requested_cpu_milli"] for node in nodes)
        requested_memory = sum(node["requested_memory_bytes"] for node in nodes)
        ready = (len(nodes) == 3 and sum(node["eligible_worker"] for node in nodes) == 2
                 and sum(node["role"] == "Control plane" and node["ready"] == "Ready" for node in nodes) == 1)
        return jsonify(
            connected=True, context=context, cluster=context.removeprefix("kind-"),
            topology_ready=ready, nodes=nodes, cluster_info=context,
            metrics_available=bool(usage), metrics_message=metrics_message or
            ("Actual usage is reported per node where Metrics Server has a sample." if usage
             else "Metrics Server has no node usage samples yet."),
            priority_classes=[{"name": pc["metadata"]["name"], "value": pc["value"],
                               "global_default": pc.get("globalDefault", False),
                               "description": pc.get("description", ""),
                               "policy": pc.get("preemptionPolicy", "PreemptLowerPriority")} for pc in classes],
            resources={"total_cpu_milli": cpu, "committed_cpu_milli": requested_cpu,
                       "cpu_percentage": round(100 * requested_cpu / cpu, 1) if cpu else None,
                       "allocatable_memory": f"{memory / 2**30:.2f} GiB",
                       "allocatable_memory_bytes": memory, "requested_memory_bytes": requested_memory,
                       "memory_percentage": round(100 * requested_memory / memory, 1) if memory else None})
    except (ClusterError, KeyError, ValueError, IndexError) as exc:
        return jsonify(connected=False, error=str(exc), nodes=[])


def format_event(event):
    subject = event.get("involvedObject", {})
    metadata = event["metadata"]
    source = event.get("reportingComponent") or event.get("source", {}).get("component", "")
    return {
        "uid": metadata["uid"], "pod_uid": subject.get("uid"),
        "timestamp": (event.get("series", {}).get("lastObservedTime") or event.get("lastTimestamp")
                      or event.get("eventTime") or metadata["creationTimestamp"]),
        "created_at": metadata["creationTimestamp"], "type": event.get("type", "Normal"),
        "reason": event.get("reason", "Unknown"), "object": f"{subject.get('kind')}/{subject.get('name')}",
        "message": event.get("message", ""), "source": source,
        "preemption": source == "default-scheduler" and event.get("reason") == "Preempted"
        and subject.get("kind") == "Pod",
    }


def read_csv(path):
    if path is None or not path.is_file():
        return []
    with path.open(encoding="utf-8-sig", newline="") as file:
        return list(csv.DictReader(file))


def latest_run(context, experiment, required_file="outcome.json"):
    directory = RESULTS_DIR / context / experiment
    return next((summary.parent for summary in sorted(directory.glob("*/outcome.json"), reverse=True)
                 if (summary.parent / required_file).is_file()), None)


def archived_victims(context):
    run = latest_run(context, "experiment-2", RESULT_FILES["experiment-2"])
    if run is None:
        return []
    return [row for row in read_csv(run / RESULT_FILES["experiment-2"]) if row["PreemptionStatus"] == "Confirmed"]


def format_pod(pod, victim_uids):
    metadata, spec = pod["metadata"], pod["spec"]
    status = pod.get("status", {})
    scheduled = next((c.get("lastTransitionTime") for c in status.get("conditions", [])
                      if c["type"] == "PodScheduled" and c["status"] == "True"), None)
    created = metadata["creationTimestamp"]
    latency = "N/A"
    if scheduled:
        start, end = (datetime.fromisoformat(t.replace("Z", "+00:00")) for t in (created, scheduled))
        latency = round(max(0, (end - start).total_seconds()), 3)
    disrupted = any(c["type"] == "DisruptionTarget" and c["status"] == "True"
                    and c.get("reason") == "PreemptionByScheduler" for c in status.get("conditions", []))
    started = next((c["state"]["running"].get("startedAt", "N/A") for c in status.get("containerStatuses", [])
                    if c.get("state", {}).get("running")), "N/A")
    memory = round_up(pod_request(pod, "memory"))
    scheduling_failure = next((c.get("message", "") for c in status.get("conditions", [])
                               if c["type"] == "PodScheduled" and c["status"] == "False"), "")
    waiting = next((c["state"]["waiting"] for c in status.get("containerStatuses", [])
                    if c.get("state", {}).get("waiting")), {})
    phase = status.get("phase", "Unknown")
    display = "Terminating" if metadata.get("deletionTimestamp") else phase
    if display == "Pending" and waiting.get("reason"):
        display = waiting["reason"]
    return {
        "name": metadata["name"], "uid": metadata["uid"], "labels": metadata.get("labels", {}),
        "priority_class": spec.get("priorityClassName", "none"), "priority_value": spec.get("priority", 0),
        "status": display, "phase": phase,
        "scheduling_reason": scheduling_failure or waiting.get("message") or status.get("message", ""),
        "nominated_node": status.get("nominatedNodeName"),
        "preempted": disrupted or metadata["uid"] in victim_uids, "archived": False,
        "node": spec.get("nodeName", "Pending / Unassigned"),
        "assigned_node": spec.get("nodeName"), "node_selector": spec.get("nodeSelector", {}),
        "affinity": spec.get("affinity", {}), "preemption_policy": spec.get("preemptionPolicy", ""),
        "cpu_request": f"{round_up(pod_request(pod, 'cpu') * 1000)}m",
        "memory_request": f"{memory / 2**20:g}Mi" if memory >= 2**20 else str(memory),
        "created_at": created, "scheduled_at": scheduled or "N/A", "started_at": started, "latency_sec": latency,
    }


@app.route("/api/pods")
def get_pods():
    try:
        data = kubectl_json("get", "pods", "-n", NAMESPACE)
        events = [format_event(event) for event in kubectl_json("get", "events", "-n", NAMESPACE)["items"]]
        victims = archived_victims(get_lab_context())
        victim_uids = {ev["pod_uid"] for ev in events if ev["preemption"]} | {r["PodUID"] for r in victims}
        pods = [format_pod(pod, victim_uids) for pod in data["items"]]
        live_uids = {pod["uid"] for pod in pods}
        for row in victims:
            if row["PodUID"] not in live_uids:
                pods.append({
                    "name": row["PodName"], "uid": row["PodUID"], "labels": {"experiment": row["Experiment"]},
                    "priority_class": row["PriorityClass"], "priority_value": int(row["PriorityValue"]),
                    "status": "Deleted (recorded)", "preempted": True, "archived": True,
                    "node": row["Node"], "cpu_request": row["CpuRequest"], "memory_request": row["MemoryRequest"],
                    "created_at": row["CreationTime"], "scheduled_at": row["ScheduledTime"],
                    "started_at": row["StartTime"], "latency_sec": "N/A",
                })
        owned = [p for p in pods if p["labels"].get(OWNER_LABEL) == "priority-scheduling-lab"]
        active = sorted({p["labels"]["experiment"] for p in owned if "experiment" in p["labels"]})
        order = [p for p in owned if p["labels"].get("experiment") == "scheduling-order"]
        blocker = next((p for p in order if p["labels"].get("role") == "blocker"), None)
        contestants = [p for p in order if p["labels"].get("role") == "contestant"]
        pending = (blocker and blocker["status"] == "Running" and len(contestants) == 2
                   and all(p["status"] == "Pending" and "Insufficient cpu" in p["scheduling_reason"]
                           and p["labels"].get("lab-run") == blocker["labels"].get("lab-run") for p in contestants))
        return jsonify(success=True, pods=pods, active_experiments=active, order_pending=bool(pending))
    except (ClusterError, KeyError, ValueError, IndexError, OSError) as exc:
        return jsonify(success=False, error=str(exc), pods=[])


@app.route("/api/events")
def get_events():
    try:
        context = get_lab_context()
        events = {}
        run = latest_run(context, "experiment-2", "kubernetes-events.csv")
        if run:
            for row in read_csv(run / "kubernetes-events.csv"):
                events[row["EventUID"]] = {
                    "uid": row["EventUID"], "pod_uid": row["PodUID"], "timestamp": row["LastTimestamp"],
                    "created_at": row["FirstTimestamp"], "type": row["Type"], "reason": row["Reason"],
                    "object": row["InvolvedObject"], "message": row["Message"], "source": row["Source"],
                    "preemption": row["Reason"] == "Preempted" and row["Source"] == "default-scheduler"
                    and row["InvolvedObject"].startswith("Pod/"), "archived": True,
                }
        for raw in kubectl_json("get", "events", "-n", NAMESPACE)["items"]:
            event = format_event(raw)
            events[event["uid"]] = event
        return jsonify(events=sorted(events.values(), key=lambda event: (event["created_at"], event["timestamp"])))
    except (ClusterError, KeyError, ValueError, IndexError, OSError) as exc:
        return jsonify(events=[], error=str(exc))


def read_evidence(folder, name, default=None):
    file = folder / name
    return json.loads(file.read_text(encoding="utf-8-sig")) if file.is_file() else default


def timestamp_key(value):
    # Preserve the full RFC3339 fractional part. datetime and JavaScript Date
    # alone would truncate real Kubernetes timestamps to micro/milliseconds.
    match = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)", value or "")
    if not match:
        return (datetime.min.replace(tzinfo=timezone.utc), Decimal(0))
    base, fraction, offset = match.groups()
    return (datetime.fromisoformat(base + offset.replace("Z", "+00:00")),
            Decimal("0." + (fraction or "0")))


def audit_pod_maps(run, current_pods):
    baseline = read_evidence(run, "baseline-pods.json", [])
    final = read_evidence(run, "final-pods.json", [])
    observed = read_evidence(run, "observed-pods.json", [])
    probe = read_evidence(run, "equal-pending-pod.json")
    combined = baseline + ([probe] if probe else []) + observed + final + current_pods
    pods_by_uid = {pod["metadata"]["uid"]: pod for pod in combined
                   if isinstance(pod, dict) and pod.get("metadata", {}).get("uid") and "spec" in pod}
    return baseline, final, pods_by_uid


def run_event_rows(run, current_pods, pod_map, live_events, observation_stage, newest):
    snapshots = {}
    stages = {}
    for stage in ("Prepare", "Equal", "Preempt"):
        for path in sorted(run.glob(f"events-{stage.lower()}-*.json")):
            for event in read_evidence(run, path.name)["items"]:
                uid = event.get("involvedObject", {}).get("uid")
                if uid in pod_map:
                    event_uid = event["metadata"]["uid"]
                    snapshots[event_uid] = event
                    stages.setdefault(event_uid, stage)
    for event in live_events:
        if event.get("involvedObject", {}).get("uid") in pod_map:
            event_uid = event["metadata"]["uid"]
            snapshots[event_uid] = event
            stages.setdefault(event_uid, observation_stage)

    rows = []
    live_uids = {event["metadata"]["uid"] for event in live_events}
    for event_uid, raw in snapshots.items():
        event = format_event(raw)
        pod = pod_map[event["pod_uid"]]
        spec = pod["spec"]
        first = (raw.get("eventTime") or raw.get("firstTimestamp") or raw["metadata"].get("creationTimestamp"))
        last = raw.get("series", {}).get("lastObservedTime") or raw.get("lastTimestamp") or first
        node = spec.get("nodeName")
        hostname = spec.get("nodeSelector", {}).get("kubernetes.io/hostname")
        event.update(timestamp=first, last_observed=last, occurrences=raw.get("series", {}).get("count") or raw.get("count") or 1,
                     raw=raw, run_id=run.name, stage=stages[event_uid], workload=pod["metadata"]["name"],
                     node=node or hostname, node_basis="Assignment" if node else "Requested hostname" if hostname else "",
                     origin="Live API" if event_uid in live_uids else "Saved API snapshot")
        rows.append(event)

    if not rows and not current_pods:
        # Older runs saved only the normalized event CSV.
        for row in read_csv(run / "kubernetes-events.csv"):
            rows.append({"uid": row.get("EventUID"), "pod_uid": row.get("PodUID"), "run_id": run.name,
                         "timestamp": row.get("FirstTimestamp") or row.get("LastTimestamp"),
                         "last_observed": row.get("LastTimestamp"), "type": row.get("Type"),
                         "reason": row.get("Reason"), "message": row.get("Message"), "source": row.get("Source"),
                         "workload": row.get("InvolvedObject", "").removeprefix("Pod/"), "stage": None,
                         "node": None, "origin": "Legacy CSV", "raw": None})
    # Stable sorting retains source order for ties. Missing timestamps stay at the end.
    timed = [row for row in rows if row["timestamp"]]
    return sorted(timed, key=lambda row: timestamp_key(row["timestamp"]), reverse=newest) + [
        row for row in rows if not row["timestamp"]]


def preemption_workflow(run, live_pods):
    prepare = read_evidence(run, "stage-prepare.json")
    equal = read_evidence(run, "stage-equal.json")
    started = read_evidence(run, "stage-preempt-start.json")
    outcome = read_evidence(run, "outcome.json")
    compared = read_evidence(run, "stage-compare.json")
    expected = set(prepare["evidence"]["baselinePodUids"].values()) if prepare else set()
    probes = set(equal["evidence"]["probePodUids"].values()) if equal else set()
    actual = {pod["metadata"]["uid"] for pod in live_pods}
    if compared:
        phase = "Compared"
    elif outcome:
        phase = "Preemption recorded"
    elif started:
        phase = "Preempt"
    elif equal:
        phase = "Equal" if actual == expected | probes else "Needs reset"
    elif prepare:
        phase = "Prepared" if actual == expected else "Needs reset"
    else:
        phase = "Prepare"
    baseline_ready = all(
        pod.get("status", {}).get("phase") == "Running" and not pod["metadata"].get("deletionTimestamp")
        for pod in live_pods if pod["metadata"]["uid"] in expected)
    probe_pending = any(
        pod["metadata"]["uid"] in probes and pod.get("status", {}).get("phase") == "Pending"
        and not pod["spec"].get("nodeName") and not pod["metadata"].get("deletionTimestamp")
        for pod in live_pods)
    controls = {"equal": phase == "Prepared" and baseline_ready,
                "preempt": phase == "Equal" and baseline_ready and probe_pending,
                "compare": phase == "Preemption recorded" and (run / "final-pods.json").is_file()}
    steps = [{"stage": checkpoint["stage"], "started_at": checkpoint["started_at"],
              "finished_at": checkpoint["finished_at"]}
             for checkpoint in (prepare, equal) if checkpoint]
    if started:
        steps.append({"stage": "Preempt", "started_at": started["started_at"],
                      "finished_at": outcome["recorded_at"] if outcome else None})
    if compared:
        steps.append({"stage": "Compare", "started_at": compared["started_at"], "finished_at": compared["finished_at"]})
    failures = [read_evidence(run, file.name) for file in sorted(run.glob("failed-*.json"))]
    if failures and not outcome:
        phase = "Needs reset"
        controls = dict.fromkeys(controls, False)
    return phase, controls, steps, failures, prepare, equal, outcome, compared


@app.get("/api/preemption")
def get_preemption_audit():
    try:
        context = get_lab_context()
        root = RESULTS_DIR / context / "experiment-2"
        selector = "app.kubernetes.io/managed-by=priority-scheduling-lab,experiment=experiment-2"
        live_pods = kubectl_json("get", "pods", "-n", NAMESPACE, "-l", selector)["items"]
        run_ids = {pod["metadata"].get("labels", {}).get("lab-run", "") for pod in live_pods}
        active = next(iter(run_ids)) if len(run_ids) == 1 else ""
        active = active if RUN_PATTERN.fullmatch(active) and (root / active).is_dir() else None
        runs = [p.name for p in sorted(root.glob("*"), reverse=True) if p.is_dir() and RUN_PATTERN.fullmatch(p.name)
                and p.name != active]
        selection = request.args.get("run", "current")
        current = selection == "current"
        selected = active if current else selection
        if not current and selected not in runs:
            return jsonify(error="Unknown saved Experiment 3 run."), 404
        controls = {"prepare": not live_pods, "equal": False, "preempt": False, "compare": False}
        if not selected:
            return jsonify(active_run=active, run_id=None, saved_runs=runs, controls=controls, events=[],
                           phase="Needs reset" if live_pods else "Ready", current=current)

        run = root / selected
        current_pods = live_pods if current else []
        phase, allowed, steps, failures, prepare, equal, outcome, compared = preemption_workflow(run, current_pods)
        if current:
            controls.update(allowed)
        else:
            controls["prepare"] = False
        baseline, final, pod_map = audit_pod_maps(run, current_pods)
        live_events = kubectl_json("get", "events", "-n", NAMESPACE)["items"] if current else []
        observing = "Preempt" if (run / "stage-preempt-start.json").is_file() else (
            "Equal" if any(p["metadata"].get("labels", {}).get("role") == "equal-probe" for p in current_pods) else "Prepare")
        rows = run_event_rows(run, current_pods, pod_map, live_events, observing, request.args.get("order") != "oldest")
        facets = {key: sorted({row[key] for row in rows if row.get(key)}) for key in ("stage", "node", "workload", "reason")}
        rows = [row for row in rows if all(not request.args.get(key) or row.get(key) == request.args[key] for key in facets)]

        details = (outcome or {}).get("details") or {}
        victim_uids = set(details.get("confirmedVictimUids", []))
        final_map = {pod["metadata"]["uid"]: pod for pod in final}
        final_snapshot = (run / "final-pods.json").is_file()
        current_uids = {pod["metadata"]["uid"] for pod in current_pods}
        high_uids = set(details.get("highPodUids", {}).values())
        def row_for(pod, classification, state=None):
            row = dict(format_pod(pod, victim_uids), classification=classification)
            if state:
                row["status"] = state
            return row

        def after_row(uid, incoming=False):
            if uid in final_map:
                classification = "Incoming" if incoming else "Preempted" if uid in victim_uids else "Survived"
                return row_for(final_map[uid], classification)
            classification = "Incoming" if incoming else "Preempted" if uid in victim_uids else "Unconfirmed"
            state = "Absent at final snapshot" if final_snapshot else "Final state unobserved"
            return row_for(pod_map[uid], classification, state)
        comparison = None
        if outcome and (compared or not current):
            comparison = {"verdict": outcome["status"], "message": outcome["message"], "workers": details.get("workers", []),
                          "before": [row_for(pod, "Original") for pod in baseline],
                          "after": [after_row(pod["metadata"]["uid"]) for pod in baseline] +
                                   [after_row(uid, incoming=True) for uid, pod in pod_map.items() if uid in high_uids]}
        return jsonify(current=current, active_run=active, run_id=selected, saved_runs=runs, controls=controls,
                       phase=phase if current else "Saved", steps=steps, failures=failures, events=rows, facets=facets,
                       prepared=(prepare or {}).get("evidence"), equal=(equal or {}).get("evidence"),
                       workloads=[row_for(pod, "Live" if uid in current_uids else "Saved")
                                  for uid, pod in pod_map.items()], comparison=comparison)
    except (ClusterError, KeyError, ValueError, IndexError, OSError) as exc:
        return jsonify(error=str(exc)), 503


@app.get("/api/preemption/manifest/<run_id>/<pod_name>")
def get_preemption_manifest(run_id, pod_name):
    if not RUN_PATTERN.fullmatch(run_id) or not POD_NAME_PATTERN.fullmatch(pod_name):
        return jsonify(error="Invalid run or workload identifier."), 400
    try:
        run = RESULTS_DIR / get_lab_context() / "experiment-2" / run_id
        for suffix, content_type in (("-admitted.yaml", "text/yaml"), ("-manifest.json", "application/json")):
            file = run / (pod_name + suffix)
            if file.is_file():
                return app.response_class(file.read_text(encoding="utf-8-sig"), mimetype=content_type)
        return jsonify(error="No saved manifest for this Pod."), 404
    except (ClusterError, ValueError, OSError) as exc:
        return jsonify(error=str(exc)), 503


@app.route("/api/results")
def get_results():
    data = {"exp1": [], "exp2": [], "order": [], "all": [], "outcomes": {}, "timelines": {}}
    try:
        context = get_lab_context()
        for key, experiment in (("exp1", "experiment-1"), ("order", "scheduling-order"),
                                ("exp2", "experiment-2"), ("all", "all")):
            run = latest_run(context, experiment)
            if run:
                data[key] = read_csv(run / RESULT_FILES[experiment])
                outcome = json.loads((run / "outcome.json").read_text(encoding="utf-8-sig"))
                outcome["run_id"] = run.name
                data["outcomes"][experiment] = outcome
                if experiment != "all":
                    data["timelines"][experiment] = [
                        event for event in read_csv(run / "kubernetes-events.csv")
                        if event["Reason"] in EVENT_EVIDENCE and event["Source"] == "default-scheduler"
                    ]
        return jsonify(data)
    except (ClusterError, KeyError, ValueError, IndexError, OSError) as exc:
        return jsonify(**data, error=str(exc))


@app.route("/api/action/<action_name>", methods=["POST"])
def execute_action(action_name):
    if action_name not in ACTIONS:
        return jsonify(success=False, error="Unknown lab action."), 400
    stdout, stderr, code = run_powershell_script(action_name)
    stage = "PENDING" if code == 0 and "LAB_STAGE=PENDING" in stdout.splitlines() else None
    verdict = re.findall(r"^LAB_STATUS=(PASS|FAIL|INCONCLUSIVE)$", stdout, flags=re.MULTILINE)
    status = stage or (verdict[-1] if verdict and code >= 0 else ("PASS" if code == 0 else "FAIL"))
    return jsonify(success=code == 0, exit_code=code, stdout=stdout, stderr=stderr, stage=stage, status=status)


@app.route("/api/export-csv")
def export_csv():
    target = request.args.get("file")
    if target is not None and target not in {*RESULT_FILES.values(), "kubernetes-events.csv"}:
        return jsonify(error="Unknown CSV export."), 400
    try:
        context = get_lab_context()
        candidates = []
        for experiment, name in RESULT_FILES.items():
            if target and target not in (name, "kubernetes-events.csv"):
                continue
            filename = target or name
            run = latest_run(context, experiment, filename)
            if run:
                candidates.append((run, filename))
        if candidates:
            run, filename = max(candidates, key=lambda pair: pair[0].name)
            return send_from_directory(run, filename, as_attachment=True)
        return jsonify(error="No kind CSV result files found for this context. Run an experiment first."), 404
    except (ClusterError, KeyError, ValueError, IndexError) as exc:
        return jsonify(error=str(exc)), 503


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"Kubernetes Priority Scheduling Dashboard at http://127.0.0.1:{port}")
    app.run(host="127.0.0.1", port=port, debug=False)
