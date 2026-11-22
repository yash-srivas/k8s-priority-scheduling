# Project Explanation for Cloud Computing Lab Evaluation 2

## 1. What the faculty wants

Problem 05 asks me to configure several Pod priorities and show what happens when there is limited space on the workers. The evaluator wants normal Pods, an observed scheduling winner, Pending Pods with reasons, genuine preemption, and a fair comparison of priority values.

Think of payment work and a background analytics job. Both need a worker. When there is space, both can run. If there is only one slot, priority helps the scheduler decide which eligible waiting Pod to consider. If important work arrives after available CPU requests have been reserved, the scheduler may preempt lower-priority work. This project uses Kubernetes’ default scheduler. PowerShell prepares the situation and collects evidence. The app does not implement its own scheduler or business microservices. Each demo workload runs a sleeping BusyBox container.

## 2. Architecture and what happens after create or apply

1. PowerShell invokes kubectl. **The API server** accepts the request, validates the object and admits the Pod by resolving its PriorityClass value. It persists the object in **etcd**.
2. **The default scheduler** watches for unbound Pods. It filters out nodes that cannot fit a Pod or do not match its placement constraints. It scores acceptable nodes and binds the Pod to a selected node.
3. **The kubelet** on that worker sees the binding. It asks **containerd**, the container runtime, to prepare and start the image. Kubelet reports status.
4. **The controller manager** runs control loops that respond to cluster state, such as reconciling node lifecycle and controller-owned workloads. The demo uses individual Pods, so a Deployment does not recreate a preempted victim.

One **control-plane node** runs the API server, etcd, scheduler and controllers. Two **worker nodes** run demo Pods and infrastructure. The control-plane NoSchedule taint normally keeps ordinary Pods off it. A matching toleration can make that taint pass. kind puts all three nodes in containers on one Docker Desktop WSL 2 VM.

## 3. Repository map

```text
kind-config.yaml
configs/             namespace, primary and order-only classes, standalone samples
experiments/         12-Pod manifest and fixed sample YAMLs
scripts/             setup, diagnostics, three demos, collector, cleanup, shared helpers
dashboard/
  app.py             Flask, fixed command bridge, API and results
  templates/         index.html
  static/            script.js, style.css
results/
  kind/              individually saved kind runs
  *.csv              historical exports
screenshots/         earlier dashboard previews
README.md            startup and normal use
MANUAL-DEMONSTRATION.md, FACULTY-DEMO-GUIDE.md, REQUIREMENT-TRACEABILITY.md
PROJECT-REPORT.md, PROJECT-EXPLANATION.md, VIVA-QUESTIONS.md
```

`requirements.txt` and `dashboard/requirements.txt` list Flask. The fixed Pod samples in `configs/` and the Experiment 2 examples in `experiments/` show readable YAML. The automated order and preemption scripts save the **actual dynamically calibrated JSON manifests** they use.

## 4. YAML and resource fields

| Source | Fields to understand |
| --- | --- |
| [kind-config.yaml](kind-config.yaml), lines 1–6 | `kind: Cluster` and the kind API version describe cluster configuration. `nodes` lists one control-plane role and two worker roles. |
| [namespace.yaml](configs/namespace.yaml), lines 1–5 | Kubernetes v1 Namespace with `metadata.name: priority-scheduling`. Pod and event queries use this namespace. |
| [priority-classes.yaml](configs/priority-classes.yaml), lines 1–29 | `apiVersion: scheduling.k8s.io/v1`, `kind: PriorityClass`, unique `metadata.name`, integer `value`, `globalDefault`, `preemptionPolicy` and `description`. High 100000, medium 50000, low 10000. |
| [order-priority-classes.yaml](configs/order-priority-classes.yaml), lines 1–25 | Two isolated order classes keep the 100000 and 10000 values and use `preemptionPolicy: Never`. The primary classes retain `PreemptLowerPriority`. |
| [experiment-1.yaml](experiments/experiment-1.yaml), first Pod lines 1–37 | `metadata` names the Pod and supplies its namespace and ownership/experiment labels. `spec.affinity` excludes nodes labeled control plane. `priorityClassName: high-priority` attaches the class. `containers` defines BusyBox, the sleep command, requests and limits. YAML `---` starts the next object. |
| Generated order and preemption manifests in the run folders | `nodeSelector.kubernetes.io/hostname` limits the choice to a real worker. Kubernetes still binds the Pod. `restartPolicy: Never` makes a demo container a simple one-shot process. `terminationGracePeriodSeconds` gives the victim a brief grace period. |

A CPU request of `500m` means half a core. Kubernetes checks requests against allocatable resources when placing a Pod. CPU limits cap runtime CPU time; overusing a memory limit can trigger an OOM kill. A global default class would apply to Pods without an explicit class. Our three primary classes keep that option off. A larger priority value changes preference and can change preemption eligibility. CPU and memory requests stay separate from priority.

## 5. Read the PowerShell in execution order

| Entry point and source | Input → commands → output |
| --- | --- |
| [setup.ps1](scripts/setup.ps1), from line 7 | Reads the intended context and Docker cluster list. Calls `Assert-LabIdentity` and `Assert-LabTopology`. Reuses a compatible kind cluster or creates a missing target, waits for Ready and uses `kubectl apply -f` for the namespace and class manifests. Setup supplies the foundation for the demos. |
| [lab-common.ps1](scripts/lab-common.ps1), line 90 `Assert-LabIdentity`, line 118 `Assert-LabTopology` | Checks the explicit context or the active setting, exported kind API server and CA, and three node names and roles. `Invoke-LabKubectl` at line 34 adds the verified context. The Windows mutex serializes modifying lab scripts per context; `Assert-LabDemoSlot` at line 180 rejects a conflicting stage. |
| [run-experiment-1.ps1](scripts/run-experiment-1.ps1), line 33 create | `-TimeoutSeconds` controls waiting. Submits the fixed manifest, polls selected Pods, verifies expected names, values, worker assignment and Running status, displays kube outputs and calls the collector. |
| [run-scheduling-order.ps1](scripts/run-scheduling-order.ps1), lines 24–78 helpers | `New-OrderPod` takes name, tier, role, CPU, hostname and run ID. It constructs the Pod. `Submit-OrderPod` saves it and issues `kubectl create -f <generated.json> -o json`. `Get-OrderBudget` reads all Pods. `Test-OrderPending` and `Get-OrderCpuEvents` verify the Pending CPU constraint by phase, condition and event UID. |
| [run-experiment-2.ps1](scripts/run-experiment-2.ps1), lines 43–155 helpers | `New-PreemptionPod` accepts name, tier, hostname, CPU and the equal-probe switch. `Submit-LabPod` pipes the manifest to `kubectl create -f - -o json` and saves the returned UID. `Get-SafeWorkerBudget` reads a worker and all Pods, subtracts bound requests and rejects unsafe contention. `Read-PreemptionSnapshot` keeps live states, past victim data, native events and any observed nominations. `Get-ConfirmedPreemption` matches scheduler event, victim UID, related high UID and victim state. |
| [collect-results.ps1](scripts/collect-results.ps1), lines 17–86 | Takes captured Pod/event arrays or reads live objects. Matches by Pod UID, calculates placement latency from creation to a successful PodScheduled condition, and writes Pod and event CSVs. `Write-LabOutcome` in `lab-common.ps1` saves the verdict JSON after evidence collection. |
| [cleanup.ps1](scripts/cleanup.ps1), lines 7–26 | Checks target and takes the lock. `Clear-LabExperiment` uses the namespace plus both ownership and experiment labels for a graceful kubectl deletion. Use `-ExperimentName` to target one demo. |

`check-environment.ps1` checks Windows, Docker Desktop WSL 2, kubectl, kind, accessibility, topology, namespace and primary classes. `resource-requests.ps1` and `lab-common.ps1` are supporting helpers.

## 6. Resource arithmetic with real numbers

[resource-requests.ps1](scripts/resource-requests.ps1) has `Convert-LabQuantity` at line 1, `Get-LabPodRequest` at line 20 and `Get-LabNodeBudget` at line 52. Node JSON supplies allocatable CPU and memory. All-namespace Pod JSON supplies bound nonterminal workloads. The helper adds regular container requests, accounts for restartable init sidecars, takes the highest applicable init peak, uses Pod-level requests when set, and adds Pod overhead. It also accounts for larger known allocations during a resize. The dashboard mirrors this accounting for display. Node-per-replica accounting in kind shares one real host.

**Order run on kind-worker.** The worker advertised 16000m, with 100m already reserved. Free before the blocker was 15900m. The blocker reserved 11925m, leaving 3975m. Each candidate asked for 10335m and 32Mi. After release, 15900m fits one 10335m request. Two requests would need 20670m.

**Equal vs high on the same worker.** Start with 16000m allocatable. The system used 100m in requests, the medium Pod used 1590m, and three low Pods requested 3975m each. That left **2385m**. Both the equal probe and the high Pod requested **4373m and 64Mi**. The CPU shortfall was 1988m. One low Pod frees 3975m, enough to fit high. After the native preemption and high placement, the measured free amount was 1987m. These are scheduler accounting figures. Metrics Server measures actual use independently. [Live order outcome](results/kind/kind-kind/scheduling-order/20261121-215445-0390479-fc06f964/outcome.json) · [Live comparison outcome](results/kind/kind-kind/experiment-2/20261121-215708-5099452-5cef05e1/outcome.json)

## 7. Follow the demonstrations

- **Normal Placement.** Start with the namespace and classes, then create the twelve manifest Pods. Watch kube-scheduler select eligible workers and kubelet start the containers. PASS means four per class and all twelve Running with correct classes and worker assignment. This stage verifies normal placement.
- **Prepare Pending Pods.** Start one blocker, create low first, wait for its unschedulable condition, then create high with identical requests. Verify both native CPU failures. The blocker stays Running while you inspect. **Release One Slot** rechecks conditions and the one-slot math, then deletes only the demo blocker. The scheduler places a candidate. The saved order trial passed when high had the native Scheduled event and bound while low remained unbound. Backoff and other changes can lead to INCONCLUSIVE. Separate creation order, binding, and container start time when speaking.
- **Experiment 3.** Prepare snapshots one medium and a set of low Pods per worker. Test Equal Priority pauses with the unbound comparison probe available for inspection. The equal low probe on the first worker cannot preempt equal or higher priorities and is recorded Pending. Trigger Preemption removes that unbound probe, confirms comparable capacity and baseline Pods, then submits both high Pods. Compare Results presents the actual before and after snapshots. The scheduler can filter for fit, nominate a worker, preempt lower priorities, and bind after a grace period. The run verified two native low-priority victims, both high Pods Running, and both medium Pods still Running. Actual victim choice and nominations depend on scheduler state.

## 8. Dashboard button-to-code map

`index()` in [app.py](dashboard/app.py) line 219 renders the HTML. Buttons live in [index.html](dashboard/templates/index.html) lines 131–187. [script.js](dashboard/static/script.js) handles actions in `triggerAction()` around line 548 and displays the returned status, stdout and stderr. `execute_action()` at [app.py](dashboard/app.py) line 626 maps only fixed action names. `run_powershell_script()` at line 111 constructs the argument list with a fixed script and a fixed stage for the guided experiments. The Kubernetes API returns actual Pod and event state. After the POST returns, JavaScript reads the updated APIs and redraws tables and saved evidence.

| Control | Handler and route | Backend and Kubernetes work |
| --- | --- | --- |
| Normal Placement | `triggerAction` → POST `/api/action/run-experiment-1` | PowerShell creates the fixed manifest, reads Pods, nodes, classes and events. |
| Prepare Pending Pods | `triggerAction` → POST `/api/action/prepare-scheduling-order` | Order script with `-Stage Prepare`; applies order class YAML, waits for blocker and creates both contestants. |
| Release One Slot | `triggerAction` → POST `/api/action/release-scheduling-order` | Order script with `-Stage Release`; validates current Pods/events and deletes only the selected blocker. |
| Experiment 3A–3D | POST `/api/action/prepare-preemption`, `test-equal-priority`, `trigger-preemption`, and `compare-preemption` under `/api/action/` | Each calls the corresponding PowerShell stage. The final action records that you opened the saved comparison. |
| Experiment 3 Audit / Inspect YAML | GET `/api/preemption` and `/api/preemption/manifest/<run_id>/<pod_name>` | The audit uses stage checkpoints and UID-scoped raw events. Inspect YAML reads the saved admitted manifest and does not change the Pod. |
| Refresh / Auto-Poll | `refreshAll()` → `fetchStatus`, `fetchPods`, `fetchEvents`, `fetchResults` | GET `/api/status` → `get_status` (line 224). GET `/api/pods` → `get_pods` (341). GET `/api/events` → `get_events` (373). GET `/api/results` → `get_results` (603). Kubectl returns JSON for reads; the results route reads the saved files. |
| Export Audit CSV | `exportCsv()` → GET `/api/export-csv` | `export_csv()` (line 637) serves the selected context's allowed CSV from disk. |
| Purge Workloads | `triggerAction` → POST `/api/action/cleanup` | `cleanup.ps1` runs labeled kubectl deletes. |
| Pod filters / Clear Console | `setFilter()` / `clearConsole()` | Browser-only rendering and text handling. |

`renderPreemptionOverview()` in `preemption.js` renders the four-stage audit from Kubernetes snapshots and the saved comparison. `updateDemoControls()` enables Release only in the staged Pending state. The backend independently rejects invalid transitions. Dashboard colors are visual tier labels.

## 9. Results and evidence

Each folder under `results/kind/<context>/<experiment>/<UTC-run-id>/` belongs to one run. Pod JSON captures state. Node and class snapshots provide context. CSV rows give a tabular view. `outcome.json` gives the verdict and important recorded parameters. The order test saves pre-release and final evidence. Experiment 3 checkpoints each student action separately. Its saved raw API event snapshots preserve native timestamps, and victim specifications remain available after deletion. The console shows actual commands; the saved generated manifests show their exact resource settings. Saved results display their own date. Top-level CSVs and screenshots are historical.

PASS requires stage-specific proof. FAIL covers unsuccessful commands, required state or evidence writing. INCONCLUSIVE means the controlled comparison or observations could not establish the intended result. Kubernetes events can expire and may share timestamps. Only conclude what the captured UID, binding and state support.

## 10. What to study

1. **Essential YAML:** `kind-config.yaml`, primary classes, first Pod in Experiment 1, and order-only classes. Study `priorityClassName`, requests, limits, affinities and selectors.
2. **Essential logic:** the Experiment 1 poll and validation; `Get-LabNodeBudget`; order Prepare and Release; Experiment 2 calibration, equal probe and `Get-ConfirmedPreemption`.
3. **Memorize inspection commands:** `kubectl --context kind-kind get nodes -o wide`, `get priorityclasses`, `get pods -n priority-scheduling -o wide`, `describe pod`, and sorted namespace `get events`. Use [the manual reference](MANUAL-DEMONSTRATION.md) for exact commands.
4. **Supporting code:** understand the path from `triggerAction` to the allowlist, scripts and dashboard response. Know why UID, CSV and JSON matter. CSS, icon SVGs and presentation details can stay at a high level.
5. **Optional advanced topics:** scheduler backoff, in-place resize accounting, nominated nodes, PodDisruptionBudgets and node-pressure eviction. [Kubernetes priority and preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
