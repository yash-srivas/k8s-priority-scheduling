# ==============================================================================
# Script: run-experiment-1.ps1
# Description: Executes Experiment 1 - Multi-Tier Microservice Priority Scheduling (12 Pods)
# Project: Priority-Based Pod Scheduling in Kubernetes
# ==============================================================================

[CmdletBinding()]
param (
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = "Continue"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " [EXPERIMENT 1] Multi-Tier Microservice Priority Scheduling" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Objective: Demonstrate priority-based queue reordering across" -ForegroundColor Gray
Write-Host "           12 real-world microservices across High, Medium, and Low tiers." -ForegroundColor Gray
Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigsDir = Join-Path $ProjectRoot "configs"
$ExpDir = Join-Path $ProjectRoot "experiments"
$Namespace = "priority-scheduling"

# 1. Verify cluster connection
Write-Host "`n[Step 1/5] Checking cluster status..." -ForegroundColor Yellow
$clusterInfo = kubectl cluster-info --request-timeout=4s 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Kubernetes cluster is not reachable. Run setup.ps1 first." -ForegroundColor Red
    exit 1
}

# 2. Ensure Namespace and PriorityClasses exist
Write-Host "`n[Step 2/5] Ensuring PriorityClasses and Namespace..." -ForegroundColor Yellow
kubectl apply -f (Join-Path $ConfigsDir "namespace.yaml")
kubectl apply -f (Join-Path $ConfigsDir "priority-classes.yaml")

# 3. Clean up any existing experiment pods
Write-Host "`n[Step 3/5] Cleaning up existing pods in '$Namespace'..." -ForegroundColor Yellow
kubectl delete pods -n $Namespace --all --grace-period=0 --force 2>&1 | Out-Null
Start-Sleep -Seconds 2

# 4. Deploy Experiment 1 Pods
$exp1Yaml = Join-Path $ExpDir "experiment-1.yaml"
Write-Host "`n[Step 4/5] Deploying 12 Microservice Workloads ($exp1Yaml)..." -ForegroundColor Yellow
kubectl apply -f $exp1Yaml

Write-Host "`nPods submitted to Kubernetes API. Monitoring scheduling cycle..." -ForegroundColor Cyan

# 5. Monitor Pod scheduling loop
$elapsed = 0
$allScheduled = $false

while ($elapsed -lt $TimeoutSeconds) {
    $podsRaw = kubectl get pods -n $Namespace -l experiment=experiment-1 -o json 2>&1
    if ($LASTEXITCODE -eq 0) {
        $pods = ($podsRaw | ConvertFrom-Json).items
        $pendingCount = ($pods | Where-Object { $_.status.phase -eq "Pending" }).Count
        $runningCount = ($pods | Where-Object { $_.status.phase -eq "Running" }).Count
        $totalCount = $pods.Count

        Write-Host "  [T+${elapsed}s] Total Microservices: $totalCount | Running: $runningCount | Pending: $pendingCount" -ForegroundColor DarkGray

        if ($runningCount -eq $totalCount -and $totalCount -ge 12) {
            $allScheduled = $true
            break
        }
    }
    Start-Sleep -Seconds 3
    $elapsed += 3
}

Write-Host "`n[Step 5/5] Extracting Scheduling & Priority Details..." -ForegroundColor Yellow

# Query pods with structured output
$expPodsJson = (kubectl get pods -n $Namespace -l experiment=experiment-1 -o json | ConvertFrom-Json).items

$tableOutput = @()
foreach ($p in $expPodsJson) {
    $pName = $p.metadata.name
    $pClass = $p.spec.priorityClassName
    $pValue = $p.spec.priority
    $pStatus = $p.status.phase
    $pNode = $p.spec.nodeName
    $pCreated = $p.metadata.creationTimestamp
    $container = $p.status.containerStatuses | Select-Object -First 1
    $pStarted = if ($container -and $container.state.running) { $container.state.running.startedAt } else { "Pending" }
    $serviceTag = if ($p.metadata.labels.service) { $p.metadata.labels.service } else { "workload" }

    $tableOutput += [PSCustomObject]@{
        "Microservice Name" = $pName
        "Service Tag"       = $serviceTag
        "Priority Tier"     = $pClass
        "Priority Value"    = $pValue
        "Status"            = $pStatus
        "Node"              = $pNode
        "Creation Time"     = $pCreated
        "Start Time"        = $pStarted
    }
}

Write-Host "`nMicroservice Scheduling & Priority Distribution:" -ForegroundColor Green
$tableOutput | Sort-Object "Priority Value" -Descending | Format-Table -AutoSize

Write-Host "`n[CRITICAL ACADEMIC NOTE]:" -ForegroundColor Magenta
Write-Host "Notice that Kubernetes assigns priority values directly from the PriorityClass." -ForegroundColor White
Write-Host "In Kubernetes, priority dictates position in the scheduler's internal activeQ priority queue." -ForegroundColor White
Write-Host "When multiple Pods are waiting for scheduling, higher priority Pods are evaluated first." -ForegroundColor White
Write-Host "However, visible Running order after scheduling is also influenced by container image pull times" -ForegroundColor White
Write-Host "and container initialization speeds. Scheduling order != execution completion order." -ForegroundColor White

# Save results
$collectScript = Join-Path $ScriptDir "collect-results.ps1"
if (Test-Path $collectScript) {
    & $collectScript -ExperimentName "experiment-1" -Namespace $Namespace
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host " Experiment 1 completed successfully!" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
