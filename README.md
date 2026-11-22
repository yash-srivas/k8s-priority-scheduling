# Priority-Based Pod Scheduling in Kubernetes

**Problem 05 · Cloud Computing Lab Evaluation 2.** Configure multiple Kubernetes PriorityClasses, deploy workloads with different priorities and resource requests, and demonstrate how priority influences scheduling under limited resources. Show Pod scheduling order, Pending Pods, native preemption events, and the effect of different priority values.

| Demonstration | Faculty requirement it proves | Source |
| --- | --- | --- |
| 1. Normal Placement | Valid priority classes, different priorities and requests, status and worker placement | `configs/priority-classes.yaml`, `experiments/experiment-1.yaml`, `scripts/run-experiment-1.ps1` |
| 2A. Prepare Pending Pods | Two comparable Pods genuinely blocked by limited CPU | `configs/order-priority-classes.yaml`, `scripts/run-scheduling-order.ps1 -Stage Prepare` |
| 2B. Release One Slot | A shared opportunity with an observed scheduling winner | `scripts/run-scheduling-order.ps1 -Stage Release` |
| 3A–3D. Prepare, Test Equal, Trigger, Compare | Inspect each phase of a matched equal-priority and native preemption demonstration | `scripts/run-experiment-2.ps1 -Stage Prepare/Equal/Preempt/Compare` |

See [Requirement Traceability](REQUIREMENT-TRACEABILITY.md) for the audit and live evidence, [Faculty Demo Guide](FACULTY-DEMO-GUIDE.md) for the presentation, and [Manual Demonstration](MANUAL-DEMONSTRATION.md) for the same experiments through PowerShell and kubectl.

## Architecture

```text
Browser → Flask → fixed PowerShell scripts and kubectl → Kubernetes API server
                                                              │
                       kind control plane: etcd, scheduler, controllers
                                      │                    │
                                    worker 1             worker 2
```

Windows 11 runs Docker Desktop with WSL 2 Linux containers. kind creates one control plane and two workers as Docker containers, using `kind-config.yaml`. Kubernetes' built-in scheduler makes the decisions. Each node has a kubelet and a container runtime. The demo Pods represent services by name and run sleeping BusyBox containers to keep real load small. Node-reported capacity can overlap because all nodes share one VM.

## First-time setup

Use Docker Desktop with WSL 2, kind, kubectl, Python 3.10+, and PowerShell. Start Docker Desktop with Linux containers. Keep its built-in Kubernetes feature disabled. [Docker WSL 2 setup](https://docs.docker.com/desktop/features/wsl/) · [Install kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) · [Install kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/)

From the repository root:

```powershell
kind get clusters
kubectl config get-contexts
$env:PRIORITY_KUBECTL_CONTEXT = 'kind-kind'
$env:PRIORITY_KIND_CLUSTER = 'kind'

python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r .\requirements.txt
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-environment.ps1
```

The explicit context remains local to that shell and its child processes. Setup verifies the Docker kind endpoint and CA, compares matching nodes, and checks topology. On a fresh machine with no default cluster, omit `PRIORITY_KUBECTL_CONTEXT` and let setup create the default cluster, or first run `kind create cluster --config kind-config.yaml`. The topology is one control plane and two Ready, schedulable workers. For another authorized named lab, use its exact kind name and context in both variables. [kind multi-node config](https://kind.sigs.k8s.io/docs/user/configuration/#nodes)

## Start and stop the dashboard

On a subsequent restart, keep Docker Desktop running and run only:

```powershell
$env:PRIORITY_KUBECTL_CONTEXT = 'kind-kind'
$env:PRIORITY_KIND_CLUSTER = 'kind'
.\.venv\Scripts\python.exe .\dashboard\app.py
```

Open **http://127.0.0.1:5000**. Press **Ctrl+C** in this shell to stop Flask. Use `$env:PORT = '5050'` before starting if port 5000 is in use. Flask exits independently of the kind cluster and any demo Pods. Stopping Docker Desktop pauses access to its clusters. Cluster deletion is a separate administrator action and is unnecessary for this lab.

## Demonstrate in order

1. **Normal Placement** creates 12 Pods with four at each priority. Show the assigned class name, priority value, requests, node, and status. All tiers can run when there is room. This stage establishes placement.
2. **Purge Workloads**, then **Prepare Pending Pods**. Show the two unbound contestants and their genuine `Insufficient cpu` reasons. Open the labeled CPU breakdown on the target worker. The blocker holds CPU requests until you release it.
3. **Release One Slot**. Low was created first. Both contestants have identical requests and a shared hostname selector. Their order-specific classes set `preemptionPolicy: Never`. Watch the actual winner and open the saved order timeline. A PASS requires high Running with a scheduler placement event while low stays Pending. Queue backoff and external changes can make a trial inconclusive.
4. **Purge Workloads**, then run Experiment 3 one button at a time.
   - **3A. Prepare Workloads** starts two medium and five low Pods. The saved baseline shows assignment, priority, requests and available CPU.
   - **3B. Test Equal Priority** adds the equal-priority probe. Stop here to show its genuine Pending state, requested hostname, and Insufficient cpu warning.
   - **3C. Trigger Preemption** clears only the unbound comparison probe, rechecks the baseline, and submits two high Pods. Kubernetes selects the victims.
   - **3D. Compare Results** opens the saved before/after view. Point to the surviving, preempted and incoming Pods, released requests and final free CPU.

Terminal equivalents:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-experiment-1.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -ExperimentName experiment-1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-scheduling-order.ps1 -Stage Prepare

kubectl --context kind-kind describe pod order-low-contestant -n priority-scheduling
kubectl --context kind-kind get pods -n priority-scheduling -o wide

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-scheduling-order.ps1 -Stage Release
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -ExperimentName scheduling-order
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-experiment-2.ps1 -Stage Prepare
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-experiment-2.ps1 -Stage Equal
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-experiment-2.ps1 -Stage Preempt
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-experiment-2.ps1 -Stage Compare

kubectl --context kind-kind get priorityclasses
kubectl --context kind-kind describe nodes
kubectl --context kind-kind get events -n priority-scheduling --sort-by=.metadata.creationTimestamp
kubectl --context kind-kind get events -n priority-scheduling --field-selector reason=Preempted
```

Use `-Stage Auto` to run order preparation and release together. Live PowerShell shows commands as they run. The dashboard action console shows captured script output when each action finishes. The control states and Pod table refresh while an action is active.

## Read evidence and clean up

The **Experiment 3 Audit** separates the current UID-scoped run from saved runs. Inspect admission-time Pod YAML with **Inspect YAML**. The configured selector or affinity limits eligible nodes. The assigned node shows the scheduler's binding. In the raw event table, filter by first observed stage, node, workload, or reason, and choose either time direction. The timestamps come directly from Kubernetes and ties carry no inferred order. The separate workflow timeline records when the student ran each stage. Per-run raw API snapshots, generated JSON, admitted YAML and stage checkpoints are preserved alongside the CSVs.

Experiment 3 retains the existing internal `experiment-2` ownership label, cleanup selector, script name and archive folder. Purging resets the active stages and leaves the evidence available under **Saved**.

Requested CPU is the sum charged for bound, nonterminal Pods. **Free for requests = allocatable − requested.** The dashboard presents live usage separately when Metrics Server supplies samples. All evidence used by the scheduling tests comes from the Kubernetes API.

The three primary classes use `globalDefault: false` and `PreemptLowerPriority`. An unspecified Pod gets the cluster's global default class if one exists, or priority zero otherwise. The separate order-only classes use the same high and low values and `Never`, which isolates queue preference from victim selection. [Kubernetes Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)

- **PASS** means the specific stage had all required evidence. **INCONCLUSIVE** means the controlled comparison or required evidence could not establish its result. **FAIL** means a command, staged prerequisite, expected state, or evidence collection failed.
- New Pod and event CSVs, snapshots and outcome JSON go in `results/kind/<context>/<experiment>/<UTC-run-id>/`. The latest completed or failed run is dated in the dashboard. Manual snapshots are kept apart from verified experiment outcomes. Top-level CSVs and `screenshots/` contain earlier evidence.
- **Export Audit CSV** downloads the latest eligible Pod CSV. Use `/api/export-csv?file=scheduling-order-results.csv`, `experiment-1-results.csv`, or `experiment-2-results.csv` for a particular experiment. Check run folders for the matching event CSV.
- Run `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1` or click **Purge Workloads**. The script selects the project namespace and both ownership and experiment labels. Use `-ExperimentName experiment-1`, `scheduling-order`, or `experiment-2` to clear one stage.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Docker or API unavailable | Start Docker Desktop with the WSL 2 Linux engine. Run `docker info` and `kind get clusters`. |
| Wrong or stale context | Check both environment variables and `kubectl config get-contexts`. Use `kind export kubeconfig --name kind` if the kubeconfig is stale, then recheck the selected context before changing workloads. |
| Namespace/classes missing | Run setup on the authorized context. |
| Buttons blocked | Use **Purge Workloads** when changing stages. Release activates after both owned order contestants are genuinely Pending. |
| Pod still Pending after release | Inspect the actual worker budget and scheduler events. Read the verdict rather than inferring order from a Pod start time. |
| Image error or timeout | Describe the Pod and confirm Docker can pull `busybox:1.36`. |
| Preemption inconclusive | Read the saved reason. Existing lower-priority workloads, unstable allocations or missing scheduler evidence can invalidate the comparison. |
| Actual usage unavailable | The Metrics Server API is optional. Requests, placement and events still work. |
