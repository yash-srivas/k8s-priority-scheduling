# Manual Lab Demonstration in PowerShell

Run these commands from the repository root. Keep each demonstration separate so its resource accounting is easy to explain. Use a second PowerShell window for live inspection while a script is running.

## 1. Inspect and initialize the lab

```powershell
docker info --format '{{.OSType}} | {{.OperatingSystem}} | {{.KernelVersion}}'
kind get clusters
kubectl config get-contexts
$env:PRIORITY_KUBECTL_CONTEXT = 'kind-kind'
$env:PRIORITY_KIND_CLUSTER = 'kind'
function Invoke-LabKube { & kubectl --context kind-kind @args }

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-environment.ps1

Invoke-LabKube get nodes -o wide
Invoke-LabKube get namespace priority-scheduling
Invoke-LabKube get priorityclasses
Invoke-LabKube describe node kind-worker
```

Setup verifies the Docker kind API identity, then applies [namespace.yaml](configs/namespace.yaml) and [priority-classes.yaml](configs/priority-classes.yaml). The equivalent resource commands after identity verification are `Invoke-LabKube apply -f .\configs\namespace.yaml` and `Invoke-LabKube apply -f .\configs\priority-classes.yaml`. The environment check reports three Ready nodes. Point to one control plane and two workers. In the node description, find **Taints**, **Capacity**, **Allocatable**, and **Allocated resources → Requests**. In the class table, point to 100000, 50000, and 10000 and the two policy/default columns.

## 2. Create and inspect normal Pods

The manifest [experiment-1.yaml](experiments/experiment-1.yaml) has 12 BusyBox Pods and gives each a class, CPU and memory request, and a worker eligibility rule. For a manual run, start with no other active demo. These commands create the manifest and show the actual admission and placement results.

```powershell
Invoke-LabKube create -f .\experiments\experiment-1.yaml
Invoke-LabKube wait -n priority-scheduling -l experiment=experiment-1 --for=condition=Ready pod --timeout=120s
Invoke-LabKube get pods -n priority-scheduling -l experiment=experiment-1 -o wide
Invoke-LabKube get pods -n priority-scheduling -l experiment=experiment-1 -o 'custom-columns=NAME:.metadata.name,CLASS:.spec.priorityClassName,VALUE:.spec.priority,CPU:.spec.containers[0].resources.requests.cpu,RAM:.spec.containers[0].resources.requests.memory,NODE:.spec.nodeName,PHASE:.status.phase'
Invoke-LabKube describe pod auth-service-core -n priority-scheduling
Invoke-LabKube get events -n priority-scheduling --sort-by=.metadata.creationTimestamp
```

Look for 12 rows with four Pods per tier. Point to the class, numeric priority, `Requests`, `Limits`, `Node`, and `Scheduled` event. Explain that there was enough room for all tiers, so this stage shows normal placement. The verified script `run-experiment-1.ps1` can be used in place of manual creation and also saves the run outcome. Before continuing, remove the owned normal-placement Pods.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -ExperimentName experiment-1
```

## 3. Hold two contestants Pending

Use the calibration helper to create one blocker and two comparable Pods on an eligible worker. [order-priority-classes.yaml](configs/order-priority-classes.yaml) defines two demo-specific classes with the familiar high and low values and `preemptionPolicy: Never`. Prepare prints each actual kubectl create command and saves its generated Pod manifest. JSON is the other manifest format accepted by the Kubernetes API.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-scheduling-order.ps1 -Stage Prepare
Invoke-LabKube get priorityclasses order-high-priority order-low-priority
Invoke-LabKube get pods -n priority-scheduling -l experiment=scheduling-order -o wide
Invoke-LabKube describe pod order-low-contestant -n priority-scheduling
Invoke-LabKube describe pod order-high-contestant -n priority-scheduling
Invoke-LabKube describe node kind-worker
Invoke-LabKube get events -n priority-scheduling --field-selector reason=FailedScheduling --sort-by=.metadata.creationTimestamp
```

For any worker shown by Prepare, substitute that name in `describe node`. Expect the blocker Running and both contestants Pending with an empty node assignment. Point to the Pod's requested CPU and the actual `FailedScheduling` warning. Compute **free CPU = allocatable CPU − assigned Pod CPU requests**. A contestant requests more than the current free amount. The worker after removing the blocker can hold either candidate, and cannot hold both. Both request 32Mi and the same CPU, and use the same worker selector. Explain that the low Pod was created first. The blocker stays in place while you speak.

For the latest generated manifest and evidence:

```powershell
$orderRun = Get-ChildItem .\results\kind\kind-kind\scheduling-order -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'prepared.json') } |
    Sort-Object Name -Descending | Select-Object -First 1
Get-Content (Join-Path $orderRun.FullName 'order-low-contestant.json')
Get-Content (Join-Path $orderRun.FullName 'prepared.json')
```

## 4. Release one slot and inspect the actual winner

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-scheduling-order.ps1 -Stage Release
Invoke-LabKube get pods -n priority-scheduling -l experiment=scheduling-order -o wide
Invoke-LabKube get events -n priority-scheduling --field-selector reason=Scheduled --sort-by=.metadata.creationTimestamp
Get-Content (Join-Path $orderRun.FullName 'outcome.json')
```

Release checks the staged UIDs, identical requests and one-slot inequality. It removes only the labeled blocker, using the exact command printed in the console, then observes Kubernetes. Look for high Running with a native `Scheduled` event and low still Pending. A tie, low winning, evidence expiry, or other change can prevent an order verdict. The evidence combines creation times, the two real CPU failures, a shared release, and the winning Pod's binding and event.

For an entirely manual release of the prepared Pods, read the exact run ID from `prepared.json`, confirm the two Pending conditions and capacity again, then use the following **instead of** the Release script. Use the native commands immediately afterward. This manual path has no automatic verified verdict.

```powershell
$runId = (Get-Content (Join-Path $orderRun.FullName 'prepared.json') -Raw | ConvertFrom-Json).runId
Invoke-LabKube delete pods -n priority-scheduling -l "app.kubernetes.io/managed-by=priority-scheduling-lab,experiment=scheduling-order,role=blocker,lab-run=$runId" --wait=true --timeout=30s
Invoke-LabKube get pods -n priority-scheduling -l experiment=scheduling-order -o wide
Invoke-LabKube get events -n priority-scheduling --sort-by=.metadata.creationTimestamp
```

The explicit deletion is a controlled resource release for the **order** demonstration. Both contestants have policy Never, so it does not serve as preemption evidence.

## 5. Compare equal versus high, then verify native preemption

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -ExperimentName scheduling-order
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-experiment-2.ps1 -Stage Prepare
Invoke-LabKube get pods -n priority-scheduling -l experiment=experiment-2 -o wide

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-experiment-2.ps1 -Stage Equal
Invoke-LabKube describe pod equal-priority-payment-probe -n priority-scheduling

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-experiment-2.ps1 -Stage Preempt
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-experiment-2.ps1 -Stage Compare
Invoke-LabKube get pods -n priority-scheduling -l experiment=experiment-2 -o wide
Invoke-LabKube get events -n priority-scheduling --field-selector reason=Preempted
Invoke-LabKube get events -n priority-scheduling --sort-by=.metadata.creationTimestamp
Invoke-LabKube describe pod emergency-payment-surge -n priority-scheduling
Invoke-LabKube describe node kind-worker
```

The Prepare stage reads allocatable values and bound requests across all namespaces, then creates 2 medium and 5 low sleeper Pods and saves the baseline. The Equal stage pauses with the probe still Pending so you can inspect it before moving on. It uses each worker's recalculated CPU free amount plus half of one low Pod's request (rounded up) to size the incoming high Pod. The console prints those real values and the create command. On the first worker, it first submits `equal-priority-payment-probe` at 10000 with the same incoming requests, waits for a genuine CPU warning, and records its unbound state. The Preempt stage removes that unbound probe, rechecks the baseline, then submits the high Pods at 100000. The Compare stage records that you opened the saved comparison. The existing internal label and archive folder remain `experiment-2`. Look for the scheduler's `Preempted` events joined to the intended Pod UIDs. The saved timeline is especially useful because Pending and nomination can be brief during preemption.

```powershell
$run = Get-ChildItem .\results\kind\kind-kind\experiment-2 -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'outcome.json') } |
    Sort-Object Name -Descending | Select-Object -First 1
Get-Content (Join-Path $run.FullName 'outcome.json')
Get-Content (Join-Path $run.FullName 'equal-priority-payment-probe-manifest.json')
Get-Content (Join-Path $run.FullName 'emergency-payment-surge-manifest.json')
Import-Csv (Join-Path $run.FullName 'kubernetes-events.csv') |
    Where-Object Reason -in FailedScheduling,Preempted,Scheduled |
    Format-Table FirstTimestamp,Reason,InvolvedObject,Source,PodUID,RelatedUID
Import-Csv (Join-Path $run.FullName 'experiment-2-results.csv') |
    Format-Table PodName,PriorityValue,CpuRequest,MemoryRequest,Node,Status,PreemptionStatus
```

Explain the cause: equal-priority incumbents are ineligible as victims of the equal probe. The higher priority Pod can preempt eligible lower-priority Pods when doing so makes the placement feasible. Compare the pre- and post-run `workers` CPU fields, the equal probe's CPU warning, and Running high Pods.

### Optional single-worker kubectl replay

After a documented run, the generated manifests above can be replayed without the Flask app or orchestration. Run this section in a PowerShell session that permits dot-sourcing local scripts. Use the same now-empty lab, clean up the preemption demonstration first, and make sure node allocatable and non-project requests match the saved initial snapshot. **Use the calibration script again if the budget changed.** The generated manifest carries the project labels and original selector. Create just the first worker's four baseline Pods, then the equal probe and high Pod in order. Keep remaining workers outside this single-worker exercise.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -ExperimentName experiment-2
Invoke-LabKube describe node kind-worker
. .\scripts\resource-requests.ps1
$worker = Invoke-LabKube get node kind-worker -o json | ConvertFrom-Json
$all = (Invoke-LabKube get pods -A -o json | ConvertFrom-Json).items
$budget = Get-LabNodeBudget $worker $all
$recorded = (Get-Content (Join-Path $run.FullName 'outcome.json') -Raw | ConvertFrom-Json).details.workers |
    Where-Object node -eq 'kind-worker'
if (-not $recorded -or $budget.AllocatableCpuMilli -ne $recorded.cpuAllocatableMilli -or
    $budget.RequestedCpuMilli -ne $recorded.initialRequestedCpuMilli -or
    $budget.FreeMemoryBytes -lt 192MB -or $budget.FreeSlots -lt 5 -or
    @($budget.Bound | Where-Object { [int]$_.spec.priority -lt 100000 }).Count) {
    throw 'The worker has a different budget or a possible unrelated victim. Use the calibrated script.'
}
$budget | Select-Object Node,AllocatableCpuMilli,RequestedCpuMilli,FreeCpuMilli
foreach ($name in 'customer-portal-api','batch-analytics-worker-1','video-transcoder-node-1','data-crawler-job-1') {
    Invoke-LabKube create -f (Join-Path $run.FullName "$name-manifest.json")
    if ($LASTEXITCODE) { throw "Create failed for $name" }
}
Invoke-LabKube wait -n priority-scheduling -l experiment=experiment-2 --for=condition=Ready pod --timeout=120s
Invoke-LabKube create -f (Join-Path $run.FullName 'equal-priority-payment-probe-manifest.json')
Invoke-LabKube wait -n priority-scheduling --for=condition=PodScheduled=false pod/equal-priority-payment-probe --timeout=60s
Invoke-LabKube describe pod equal-priority-payment-probe -n priority-scheduling
```

Confirm the probe is Pending and unassigned with `Insufficient cpu` and none of the baseline Pods is terminating. Then:

```powershell
Invoke-LabKube delete pods -n priority-scheduling -l 'app.kubernetes.io/managed-by=priority-scheduling-lab,experiment=experiment-2,role=equal-probe' --wait=true --timeout=30s
Invoke-LabKube create -f (Join-Path $run.FullName 'emergency-payment-surge-manifest.json')
Invoke-LabKube get events -n priority-scheduling --field-selector reason=Preempted
Invoke-LabKube get pods -n priority-scheduling -l experiment=experiment-2 -o wide
```

Repeat the read commands until a verdict is clear. This replay produces live Kubernetes evidence for the first worker. Use the automated script for a verified two-worker outcome and new CSVs.

## 6. Clean up

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1
Invoke-LabKube get pods -n priority-scheduling --show-labels
```

The selector requires project ownership and the relevant experiment label. Expect no owned demonstration Pods and retain any unrelated Pods. The cluster, project namespace, classes, and saved evidence stay available.
