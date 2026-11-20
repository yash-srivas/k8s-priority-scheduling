import os
import sys
import json
import csv
import subprocess
from datetime import datetime
from flask import Flask, render_template, jsonify, request, send_from_directory

app = Flask(__name__, static_folder="static", template_folder="templates")
app.config["TEMPLATES_AUTO_RELOAD"] = True
app.config["SEND_FILE_MAX_AGE_DEFAULT"] = 0

# Paths
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(BASE_DIR)
SCRIPTS_DIR = os.path.join(PROJECT_ROOT, "scripts")
RESULTS_DIR = os.path.join(PROJECT_ROOT, "results")

NAMESPACE = "priority-scheduling"

def run_kubectl(args, timeout=10):
    """Executes a kubectl command safely and returns (stdout, stderr, exit_code)."""
    try:
        cmd = ["kubectl"] + args
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            shell=True if sys.platform == "win32" else False
        )
        return proc.stdout.strip(), proc.stderr.strip(), proc.returncode
    except subprocess.TimeoutExpired:
        return "", f"Command timed out after {timeout}s", -1
    except FileNotFoundError:
        return "", "kubectl command not found in PATH", -2
    except Exception as e:
        return "", str(e), -3

def run_powershell_script(script_name, extra_args=None, timeout=180):
    """Executes a specific PowerShell script from the scripts directory safely."""
    script_path = os.path.join(SCRIPTS_DIR, script_name)
    if not os.path.exists(script_path):
        return "", f"Script not found: {script_name}", 404

    cmd = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path]
    if extra_args:
        cmd.extend(extra_args)

    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout
        )
        return proc.stdout, proc.stderr, proc.returncode
    except subprocess.TimeoutExpired:
        return "", f"Execution of {script_name} timed out after {timeout} seconds", -1
    except Exception as e:
        return "", str(e), -2

def parse_cpu_milli(val):
    if not val or val == "none":
        return 0
    val = str(val).strip()
    if val.endswith("m"):
        return int(val[:-1])
    try:
        return int(val) * 1000
    except ValueError:
        return 0

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/api/status")
def get_status():
    """Queries cluster health, node information, and committed hardware utilization."""
    stdout, stderr, code = run_kubectl(["cluster-info", "--request-timeout=3s"])
    if code != 0:
        return jsonify({
            "connected": False,
            "error": stderr or "Cannot reach Kubernetes cluster. Ensure Minikube is running.",
            "nodes": []
        })

    # Fetch nodes
    node_out, _, node_code = run_kubectl(["get", "nodes", "-o", "json"])
    nodes = []
    total_cpu_milli = 8000
    alloc_mem_str = "N/A"

    if node_code == 0:
        try:
            node_data = json.loads(node_out)
            for item in node_data.get("items", []):
                name = item["metadata"]["name"]
                status_ready = "Unknown"
                for cond in item.get("status", {}).get("conditions", []):
                    if cond.get("type") == "Ready":
                        status_ready = "Ready" if cond.get("status") == "True" else "NotReady"
                        break
                alloc = item.get("status", {}).get("allocatable", {})
                cpu_raw = alloc.get("cpu", "8")
                total_cpu_milli = parse_cpu_milli(cpu_raw)
                alloc_mem_str = alloc.get("memory", "N/A")

                nodes.append({
                    "name": name,
                    "ready": status_ready,
                    "allocatable_cpu": cpu_raw,
                    "allocatable_memory": alloc_mem_str,
                    "total_cpu_milli": total_cpu_milli
                })
        except Exception:
            nodes = []

    # Calculate committed CPU across all non-terminated pods
    committed_cpu_milli = 0
    all_pods_out, _, p_code = run_kubectl(["get", "pods", "-A", "-o", "json"])
    if p_code == 0:
        try:
            all_pods = json.loads(all_pods_out).get("items", [])
            for p in all_pods:
                phase = p.get("status", {}).get("phase", "")
                if phase in ["Running", "Pending"]:
                    for c in p.get("spec", {}).get("containers", []):
                        c_req = c.get("resources", {}).get("requests", {}).get("cpu", "0")
                        committed_cpu_milli += parse_cpu_milli(c_req)
        except Exception:
            pass

    cpu_pct = round(min(100.0, (committed_cpu_milli / max(1, total_cpu_milli)) * 100), 1)

    return jsonify({
        "connected": True,
        "nodes": nodes,
        "cluster_info": stdout,
        "resources": {
            "total_cpu_milli": total_cpu_milli,
            "committed_cpu_milli": committed_cpu_milli,
            "cpu_percentage": cpu_pct,
            "allocatable_memory": alloc_mem_str
        }
    })

@app.route("/api/pods")
def get_pods():
    """Queries live pods and metadata in the priority-scheduling namespace."""
    stdout, stderr, code = run_kubectl(["get", "pods", "-n", NAMESPACE, "-o", "json"])
    if code != 0:
        return jsonify({
            "success": False,
            "error": stderr,
            "pods": []
        })

    pods = []
    try:
        data = json.loads(stdout)
        for p in data.get("items", []):
            name = p["metadata"]["name"]
            labels = p["metadata"].get("labels", {})
            priority_class = p.get("spec", {}).get("priorityClassName", "none")
            priority_value = p.get("spec", {}).get("priority", 0)
            phase = p.get("status", {}).get("phase", "Unknown")
            node = p.get("spec", {}).get("nodeName", "Pending / Unassigned")
            created_at = p["metadata"].get("creationTimestamp", "N/A")
            deletion_timestamp = p["metadata"].get("deletionTimestamp", None)

            # Scheduled condition
            scheduled_time = "N/A"
            for c in p.get("status", {}).get("conditions", []):
                if c.get("type") == "PodScheduled":
                    scheduled_time = c.get("lastTransitionTime", "N/A")
                    break

            # Container details
            containers = p.get("spec", {}).get("containers", [])
            cpu_req, mem_req = "none", "none"
            if containers:
                reqs = containers[0].get("resources", {}).get("requests", {})
                cpu_req = reqs.get("cpu", "none")
                mem_req = reqs.get("memory", "none")

            # Start time
            started_at = "N/A"
            c_statuses = p.get("status", {}).get("containerStatuses", [])
            if c_statuses and "running" in c_statuses[0].get("state", {}):
                started_at = c_statuses[0]["state"]["running"].get("startedAt", "N/A")

            # Compute scheduling latency
            latency_sec = "N/A"
            if created_at != "N/A" and scheduled_time != "N/A":
                try:
                    c_dt = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
                    s_dt = datetime.fromisoformat(scheduled_time.replace("Z", "+00:00"))
                    diff = (s_dt - c_dt).total_seconds()
                    latency_sec = round(max(0.0, diff), 3)
                except Exception:
                    latency_sec = "N/A"

            status_display = phase
            if deletion_timestamp:
                status_display = "Terminating (Preempted)"

            pods.append({
                "name": name,
                "priority_class": priority_class,
                "priority_value": priority_value,
                "status": status_display,
                "node": node,
                "cpu_request": cpu_req,
                "memory_request": mem_req,
                "created_at": created_at,
                "scheduled_at": scheduled_time,
                "started_at": started_at,
                "latency_sec": latency_sec,
                "labels": labels
            })
    except Exception as e:
        return jsonify({"success": False, "error": str(e), "pods": []})

    return jsonify({"success": True, "pods": pods})

@app.route("/api/events")
def get_events():
    """Queries Kubernetes events for preemption and scheduling."""
    stdout, stderr, code = run_kubectl(["get", "events", "-n", NAMESPACE, "-o", "json"])
    if code != 0:
        return jsonify({"events": []})

    events = []
    try:
        data = json.loads(stdout)
        for ev in data.get("items", []):
            events.append({
                "timestamp": ev.get("lastTimestamp") or ev.get("firstTimestamp") or "N/A",
                "type": ev.get("type", "Normal"),
                "reason": ev.get("reason", "Unknown"),
                "object": f"{ev.get('involvedObject', {}).get('kind')}/{ev.get('involvedObject', {}).get('name')}",
                "message": ev.get("message", "")
            })
    except Exception:
        events = []

    return jsonify({"events": events})

@app.route("/api/results")
def get_results():
    """Reads latest CSV files from the results folder."""
    files = {
        "exp1": "experiment-1-results.csv",
        "exp2": "experiment-2-results.csv",
        "all": "all-pods-summary.csv"
    }

    data = {}
    for key, fname in files.items():
        fpath = os.path.join(RESULTS_DIR, fname)
        if os.path.exists(fpath):
            rows = []
            try:
                with open(fpath, mode="r", encoding="utf-8") as f:
                    reader = csv.DictReader(f)
                    for r in reader:
                        rows.append(r)
                data[key] = rows
            except Exception:
                data[key] = []
        else:
            data[key] = []

    return jsonify(data)

@app.route("/api/action/<action_name>", methods=["POST"])
def execute_action(action_name):
    """Executes a strictly whitelisted maintenance or experiment action."""
    allowed_scripts = {
        "run-experiment-1": "run-experiment-1.ps1",
        "run-experiment-2": "run-experiment-2.ps1",
        "collect-results": "collect-results.ps1",
        "cleanup": "cleanup.ps1",
        "check-env": "check-environment.ps1"
    }

    if action_name not in allowed_scripts:
        return jsonify({"success": False, "error": f"Invalid action '{action_name}'."}), 400

    script = allowed_scripts[action_name]
    stdout, stderr, code = run_powershell_script(script)

    return jsonify({
        "success": (code == 0),
        "exit_code": code,
        "stdout": stdout,
        "stderr": stderr
    })

@app.route("/api/export-csv")
def export_csv():
    """Downloads the consolidated or requested CSV result."""
    target_file = request.args.get("file", "all-pods-summary.csv")
    safe_name = os.path.basename(target_file)
    fpath = os.path.join(RESULTS_DIR, safe_name)
    if not os.path.exists(fpath):
        for alt in ["experiment-2-results.csv", "experiment-1-results.csv"]:
            alt_path = os.path.join(RESULTS_DIR, alt)
            if os.path.exists(alt_path):
                return send_from_directory(RESULTS_DIR, alt, as_attachment=True)
        return jsonify({"error": "No CSV result files found yet. Run an experiment first."}), 404

    return send_from_directory(RESULTS_DIR, safe_name, as_attachment=True)

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"[*] Kubernetes Priority Scheduling Dashboard launching on http://127.0.0.1:{port}")
    app.run(host="0.0.0.0", port=port, debug=False)
