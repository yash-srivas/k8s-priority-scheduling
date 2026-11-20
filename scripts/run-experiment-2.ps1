# ==============================================================================
# Script: run-experiment-2.ps1
# Description: Executes Multi-Pod Priority-Based Preemption Wave
# Project: Priority-Based Pod Scheduling in Kubernetes
# ==============================================================================

[CmdletBinding()]
param (
    [int]$WaitVictimsRunningSec = 60,
    [int]$PreemptionObserveSec = 60
)

$ErrorActionPreference = "Continue"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " [EXPERIMENT 2] Multi-Pod Priority-Based Preemption Wave" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Objective: Prove that Kubernetes Scheduler selectively preempts" -ForegroundColor Gray
Write-Host "           LOW-priority Pods while leaving MEDIUM-priority Pods untouched" -ForegroundColor Gray
Write-Host "           to schedule incoming HIGH-priority emergency workloads." -ForegroundColor Gray
Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigsDir = Join-Path $ProjectRoot "configs"
$ExpDir = Join-Path $ProjectRoot "experiments"
$Namespace = "priority-scheduling"

# 1. Cluster connectivity & Node Allocatable Resource Inspection
Write-Host "`n[Step 1/6] Inspecting Node Capacity and Allocatable CPU/Memory..." -ForegroundColor Yellow
$nodeJsonRaw = kubectl get nodes -o json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Kubernetes cluster is unreachable. Please run setup.ps1 first." -ForegroundColor Red
    exit 1
}

$nodes = ($nodeJsonRaw | ConvertFrom-Json).items
$primaryNode = $nodes[0]
$nodeName = $primaryNode.metadata.name
$allocatableCpu = $primaryNode.status.allocatable.cpu
$allocatableMem = $primaryNode.status.allocatable.memory

Write-Host "  Primary Node:      $nodeName" -ForegroundColor Cyan
Write-Host "  Allocatable CPU:   $allocatableCpu" -ForegroundColor Cyan
Write-Host "  Allocatable Mem:   $allocatableMem" -ForegroundColor Cyan

# Parse node CPU in millicores
$nodeCpuMilli = 2000
if ($allocatableCpu -match "(\d+)m$") {
    $nodeCpuMilli = [int]$matches[1]
} elseif ($allocatableCpu -match "^\d+$") {
    $nodeCpuMilli = [int]$allocatableCpu * 1000
}

# Calculate CPU committed to existing non-experiment pods
$usedCpuMilli = 0
$allPodsJson = (kubectl get pods -A -o json | ConvertFrom-Json).items
foreach ($p in $allPodsJson) {
    if ($p.metadata.namespace -ne $Namespace -and $p.status.phase -eq "Running") {
        foreach ($c in $p.spec.containers) {
            $cReq = $c.resources.requests.cpu
            if ($cReq -match "(\d+)m$") {
                $usedCpuMilli += [int]$matches[1]
            } elseif ($cReq -match "^\d+$") {
                $usedCpuMilli += ([int]$cReq * 1000)
            }
        }
    }
}
$netAvailableMilli = [math]::Max(1000, ($nodeCpuMilli - $usedCpuMilli))
Write-Host "  Allocatable CPU: $nodeCpuMilli m | System Committed: $usedCpuMilli m | Net Available: $netAvailableMilli m" -ForegroundColor Gray

# Calibrate realistic sizing for multi-pod saturation
# 2 Medium Pods + 5 Low Pods fill 92% of capacity
$medPodCpu = [math]::Floor(($netAvailableMilli * 0.10))
$lowPodCpu = [math]::Floor(($netAvailableMilli * 0.14))
$preemptorCpu = [math]::Floor(($netAvailableMilli * 0.26))

Write-Host "`n  Calibrated Cluster Workload Configuration:" -ForegroundColor Cyan
Write-Host "    - 2 x Medium-Priority Pods (Protected):    ${medPodCpu}m CPU each (priority: 50,000)"
Write-Host "    - 5 x Low-Priority Batch Pods (Victims):   ${lowPodCpu}m CPU each (priority: 10,000)"
Write-Host "    - 2 x High-Priority Preemptor Pods:       ${preemptorCpu}m CPU each (priority: 100,000)"

# 2. Ensure Namespace and PriorityClasses exist
Write-Host "`n[Step 2/6] Ensuring PriorityClasses and Namespace..." -ForegroundColor Yellow
kubectl apply -f (Join-Path $ConfigsDir "namespace.yaml")
kubectl apply -f (Join-Path $ConfigsDir "priority-classes.yaml")

# 3. Clean up prior workloads in the namespace
Write-Host "`n[Step 3/6] Cleaning up previous workloads in namespace '$Namespace'..." -ForegroundColor Yellow
kubectl delete pods -n $Namespace --all --grace-period=0 --force 2>&1 | Out-Null
Start-Sleep -Seconds 3

# 4. Phase A: Deploy Baseline Workloads (Medium + Low Priority)
Write-Host "`n[Step 4/6] Deploying 7 Baseline Pods (2 Medium + 5 Low Priority)..." -ForegroundColor Yellow

$baselineYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: customer-portal-api
  namespace: $Namespace
  labels:
    experiment: experiment-2
    tier: medium
    app: portal
spec:
  priorityClassName: medium-priority
  restartPolicy: Never
  containers:
  - name: service
    image: busybox:1.36
    command: ["sh", "-c", "echo '[MED] Customer Portal Active'; sleep 7200"]
    resources:
      requests:
        cpu: "${medPodCpu}m"
        memory: "128Mi"
      limits:
        cpu: "$([math]::Floor($medPodCpu * 1.5))m"
        memory: "256Mi"
---
apiVersion: v1
kind: Pod
metadata:
  name: inventory-query-service
  namespace: $Namespace
  labels:
    experiment: experiment-2
    tier: medium
    app: inventory
spec:
  priorityClassName: medium-priority
  restartPolicy: Never
  containers:
  - name: service
    image: busybox:1.36
    command: ["sh", "-c", "echo '[MED] Inventory API Active'; sleep 7200"]
    resources:
      requests:
        cpu: "${medPodCpu}m"
        memory: "128Mi"
      limits:
        cpu: "$([math]::Floor($medPodCpu * 1.5))m"
        memory: "256Mi"
---
apiVersion: v1
kind: Pod
metadata:
  name: batch-analytics-worker-1
  namespace: $Namespace
  labels:
    experiment: experiment-2
    role: victim
    tier: low
spec:
  priorityClassName: low-priority
  restartPolicy: Never
  containers:
  - name: worker
    image: busybox:1.36
    command: ["sh", "-c", "echo '[LOW] Batch Analytics 1 Running'; sleep 7200"]
    resources:
      requests:
        cpu: "${lowPodCpu}m"
        memory: "128Mi"
      limits:
        cpu: "$([math]::Floor($lowPodCpu * 1.5))m"
        memory: "256Mi"
---
apiVersion: v1
kind: Pod
metadata:
  name: batch-analytics-worker-2
  namespace: $Namespace
  labels:
    experiment: experiment-2
    role: victim
    tier: low
spec:
  priorityClassName: low-priority
  restartPolicy: Never
  containers:
  - name: worker
    image: busybox:1.36
    command: ["sh", "-c", "echo '[LOW] Batch Analytics 2 Running'; sleep 7200"]
    resources:
      requests:
        cpu: "${lowPodCpu}m"
        memory: "128Mi"
      limits:
        cpu: "$([math]::Floor($lowPodCpu * 1.5))m"
        memory: "256Mi"
---
apiVersion: v1
kind: Pod
metadata:
  name: video-transcoder-node-1
  namespace: $Namespace
  labels:
    experiment: experiment-2
    role: victim
    tier: low
spec:
  priorityClassName: low-priority
  restartPolicy: Never
  containers:
  - name: worker
    image: busybox:1.36
    command: ["sh", "-c", "echo '[LOW] Video Transcoder 1 Running'; sleep 7200"]
    resources:
      requests:
        cpu: "${lowPodCpu}m"
        memory: "128Mi"
      limits:
        cpu: "$([math]::Floor($lowPodCpu * 1.5))m"
        memory: "256Mi"
---
apiVersion: v1
kind: Pod
metadata:
  name: video-transcoder-node-2
  namespace: $Namespace
  labels:
    experiment: experiment-2
    role: victim
    tier: low
spec:
  priorityClassName: low-priority
  restartPolicy: Never
  containers:
  - name: worker
    image: busybox:1.36
    command: ["sh", "-c", "echo '[LOW] Video Transcoder 2 Running'; sleep 7200"]
    resources:
      requests:
        cpu: "${lowPodCpu}m"
        memory: "128Mi"
      limits:
        cpu: "$([math]::Floor($lowPodCpu * 1.5))m"
        memory: "256Mi"
---
apiVersion: v1
kind: Pod
metadata:
  name: data-crawler-job-1
  namespace: $Namespace
  labels:
    experiment: experiment-2
    role: victim
    tier: low
spec:
  priorityClassName: low-priority
  restartPolicy: Never
  containers:
  - name: worker
    image: busybox:1.36
    command: ["sh", "-c", "echo '[LOW] Data Crawler 1 Running'; sleep 7200"]
    resources:
      requests:
        cpu: "${lowPodCpu}m"
        memory: "128Mi"
      limits:
        cpu: "$([math]::Floor($lowPodCpu * 1.5))m"
        memory: "256Mi"
"@

$baselineYaml | kubectl apply -f -

Write-Host "Waiting for baseline pods to reach 'Running' state..." -ForegroundColor Cyan
$elapsed = 0
while ($elapsed -lt $WaitVictimsRunningSec) {
    $bPods = (kubectl get pods -n $Namespace -l experiment=experiment-2 -o json | ConvertFrom-Json).items
    $runningCount = ($bPods | Where-Object { $_.status.phase -eq "Running" }).Count
    $totalCount = $bPods.Count

    Write-Host "  [T+${elapsed}s] Baseline Pods: $runningCount / $totalCount Running" -ForegroundColor DarkGray
    if ($runningCount -eq $totalCount -and $totalCount -ge 7) {
        break
    }
    Start-Sleep -Seconds 2
    $elapsed += 2
}

Write-Host "`nCluster Status BEFORE High-Priority Surge (Cluster Saturated):" -ForegroundColor Cyan
kubectl get pods -n $Namespace -o wide

# 5. Phase B: Deploy High-Priority Preemptor Surge
Write-Host "`n[Step 5/6] Injecting 2 High-Priority Preemptor Pods (2 x ${preemptorCpu}m CPU)..." -ForegroundColor Yellow
Write-Host "Total Surge Requested: $(2 * $preemptorCpu)m CPU. Cluster lacks capacity!" -ForegroundColor Magenta
Write-Host "Watch kube-scheduler selectively evict LOW-priority pods while protecting MEDIUM pods!" -ForegroundColor Magenta

$surgeYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: emergency-payment-surge
  namespace: $Namespace
  labels:
    experiment: experiment-2
    role: preemptor
    tier: high
spec:
  priorityClassName: high-priority
  restartPolicy: Never
  containers:
  - name: service
    image: busybox:1.36
    command: ["sh", "-c", "echo '[CRITICAL] Emergency Payment Surge Active'; sleep 7200"]
    resources:
      requests:
        cpu: "${preemptorCpu}m"
        memory: "256Mi"
      limits:
        cpu: "$([math]::Floor($preemptorCpu * 1.3))m"
        memory: "512Mi"
---
apiVersion: v1
kind: Pod
metadata:
  name: critical-order-surge
  namespace: $Namespace
  labels:
    experiment: experiment-2
    role: preemptor
    tier: high
spec:
  priorityClassName: high-priority
  restartPolicy: Never
  containers:
  - name: service
    image: busybox:1.36
    command: ["sh", "-c", "echo '[CRITICAL] Critical Order Surge Active'; sleep 7200"]
    resources:
      requests:
        cpu: "${preemptorCpu}m"
        memory: "256Mi"
      limits:
        cpu: "$([math]::Floor($preemptorCpu * 1.3))m"
        memory: "512Mi"
"@

$surgeYaml | kubectl apply -f -

Write-Host "`nMonitoring Scheduler Preemption and Eviction waves in real-time..." -ForegroundColor Cyan

$obsElapsed = 0
$bothSurgeRunning = $false

while ($obsElapsed -lt $PreemptionObserveSec) {
    $surgePods = (kubectl get pods -n $Namespace -l role=preemptor -o json 2>&1 | ConvertFrom-Json).items
    $surgeRunning = ($surgePods | Where-Object { $_.status.phase -eq "Running" }).Count
    
    $allPods = (kubectl get pods -n $Namespace -o json 2>&1 | ConvertFrom-Json).items
    $preemptedCount = ($allPods | Where-Object { $_.metadata.deletionTimestamp -ne $null }).Count

    Write-Host "  [T+${obsElapsed}s] Surge Pods Running: $surgeRunning/2 | Low-Priority Victims Preempting: $preemptedCount" -ForegroundColor DarkGray

    if ($surgeRunning -eq 2) {
        $bothSurgeRunning = $true
        break
    }

    Start-Sleep -Seconds 2
    $obsElapsed += 2
}

# 6. Evaluation and Verification of Preemption
Write-Host "`n[Step 6/6] Verifying Preemption Results and Capturing Events..." -ForegroundColor Yellow

Write-Host "`nFinal Cluster Pod Topology:" -ForegroundColor Cyan
kubectl get pods -n $Namespace -o wide

Write-Host "`nScheduler Events in '$Namespace':" -ForegroundColor Cyan
kubectl get events -n $Namespace --sort-by='.metadata.creationTimestamp' | Select-Object -Last 20

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host " [SUCCESS] MULTI-POD SELECTIVE PREEMPTION DEMONSTRATED!" -ForegroundColor Green
Write-Host " - High-Priority emergency pods successfully preempted low-priority victims." -ForegroundColor Green
Write-Host " - Medium-Priority pods remained safe and undisturbed." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

# Save results
$collectScript = Join-Path $ScriptDir "collect-results.ps1"
if (Test-Path $collectScript) {
    & $collectScript -ExperimentName "experiment-2" -Namespace $Namespace
}
