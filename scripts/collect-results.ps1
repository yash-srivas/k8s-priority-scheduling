# ==============================================================================
# Script: collect-results.ps1
# Description: Queries live Kubernetes pods & events, computes metrics and exports CSV
# Project: Priority-Based Pod Scheduling in Kubernetes
# ==============================================================================

[CmdletBinding()]
param (
    [string]$ExperimentName = "all",
    [string]$Namespace = "priority-scheduling"
)

$ErrorActionPreference = "Continue"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " [METRICS COLLECTION] Live Kubernetes Pods & Events" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ResultsDir = Join-Path $ProjectRoot "results"

if (-not (Test-Path $ResultsDir)) {
    New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
}

# 1. Fetch Pods JSON from cluster
Write-Host "`n[1/3] Querying Kubernetes API for pods in namespace '$Namespace'..." -ForegroundColor Yellow
$podsRaw = kubectl get pods -n $Namespace -o json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to query pods. Make sure cluster is reachable." -ForegroundColor Red
    Write-Host $podsRaw -ForegroundColor Yellow
    exit 1
}

$podsJson = $podsRaw | ConvertFrom-Json
$podItems = $podsJson.items

if ($null -eq $podItems -or $podItems.Count -eq 0) {
    Write-Host "[WARNING] No pods found in namespace '$Namespace'." -ForegroundColor Yellow
    exit 0
}

Write-Host "  Found $($podItems.Count) pod(s)." -ForegroundColor Green

# 2. Extract detailed metrics per pod
Write-Host "`n[2/3] Parsing scheduling timestamps and priority metrics..." -ForegroundColor Yellow

$records = @()

foreach ($pod in $podItems) {
    $pName = $pod.metadata.name
    $pClass = if ($pod.spec.priorityClassName) { $pod.spec.priorityClassName } else { "none" }
    $pValue = if ($null -ne $pod.spec.priority) { $pod.spec.priority } else { 0 }
    $pPhase = $pod.status.phase
    $pNode = if ($pod.spec.nodeName) { $pod.spec.nodeName } else { "Unassigned (Pending)" }
    $createdAtStr = $pod.metadata.creationTimestamp

    # Find PodScheduled condition
    $scheduledCond = $pod.status.conditions | Where-Object { $_.type -eq "PodScheduled" }
    $scheduledAtStr = if ($scheduledCond) { $scheduledCond.lastTransitionTime } else { "N/A" }

    # Find container start time
    $containerStatus = $pod.status.containerStatuses | Select-Object -First 1
    $startedAtStr = "N/A"
    if ($containerStatus -and $containerStatus.state.running) {
        $startedAtStr = $containerStatus.state.running.startedAt
    }

    # Calculate scheduling latency in seconds
    $schedulingLatencySec = "N/A"
    if ($createdAtStr -and $scheduledAtStr -ne "N/A") {
        try {
            $createdDt = [DateTime]::Parse($createdAtStr)
            $schedDt = [DateTime]::Parse($scheduledAtStr)
            $diff = ($schedDt - $createdDt).TotalSeconds
            $schedulingLatencySec = [math]::Round($diff, 3)
            if ($schedulingLatencySec -lt 0) { $schedulingLatencySec = 0.0 }
        } catch {
            $schedulingLatencySec = "N/A"
        }
    }

    # Extract CPU and Memory requests/limits
    $container = $pod.spec.containers | Select-Object -First 1
    $cpuReq = if ($container.resources.requests.cpu) { $container.resources.requests.cpu } else { "none" }
    $memReq = if ($container.resources.requests.memory) { $container.resources.requests.memory } else { "none" }
    $cpuLimit = if ($container.resources.limits.cpu) { $container.resources.limits.cpu } else { "none" }
    $memLimit = if ($container.resources.limits.memory) { $container.resources.limits.memory } else { "none" }

    # Extract preemption status or eviction notice
    $preemptionStatus = "None"
    if ($pod.status.reason -eq "Evicted" -or $pod.metadata.deletionTimestamp) {
        $preemptionStatus = "Preempted / Terminating"
    }

    $records += [PSCustomObject]@{
        PodName                 = $pName
        PriorityClass           = $pClass
        PriorityValue           = $pValue
        Status                  = $pPhase
        Node                    = $pNode
        CpuRequest              = $cpuReq
        MemoryRequest           = $memReq
        CpuLimit                = $cpuLimit
        MemoryLimit             = $memLimit
        CreationTime            = $createdAtStr
        ScheduledTime           = $scheduledAtStr
        StartTime               = $startedAtStr
        SchedulingLatencySec    = $schedulingLatencySec
        PreemptionStatus        = $preemptionStatus
    }
}

# Display tabular output on terminal
Write-Host "`nPod Scheduling Summary:" -ForegroundColor Cyan
$records | Format-Table -Property PodName, PriorityClass, PriorityValue, Status, Node, SchedulingLatencySec, PreemptionStatus -AutoSize

# Export Pod Metrics CSV
$timestampSuffix = (Get-Date).ToString("yyyyMMdd-HHmmss")
$csvFilename = if ($ExperimentName -ne "all") {
    "$ExperimentName-results-$timestampSuffix.csv"
} else {
    "all-pods-summary-$timestampSuffix.csv"
}
$csvLatestFilename = if ($ExperimentName -ne "all") {
    "$ExperimentName-results.csv"
} else {
    "all-pods-summary.csv"
}

$csvPath = Join-Path $ResultsDir $csvFilename
$csvLatestPath = Join-Path $ResultsDir $csvLatestFilename

$records | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
$records | Export-Csv -Path $csvLatestPath -NoTypeInformation -Encoding UTF8

Write-Host "  [SAVED] Pod metrics saved to: $csvLatestPath" -ForegroundColor Green

# 3. Collect Kubernetes Events (Preemption & Scheduling events)
Write-Host "`n[3/3] Querying Kubernetes Events..." -ForegroundColor Yellow
$eventsRaw = kubectl get events -n $Namespace -o json 2>&1
$eventRecords = @()

if ($LASTEXITCODE -eq 0) {
    $eventsJson = $eventsRaw | ConvertFrom-Json
    foreach ($ev in $eventsJson.items) {
        $eventRecords += [PSCustomObject]@{
            LastTimestamp = $ev.lastTimestamp
            Type          = $ev.type
            Reason        = $ev.reason
            InvolvedObject= "$($ev.involvedObject.kind)/$($ev.involvedObject.name)"
            Message       = $ev.message
            Source        = $ev.source.component
        }
    }
}

if ($eventRecords.Count -gt 0) {
    Write-Host "`nRecent Kubernetes Events in namespace '$Namespace':" -ForegroundColor Cyan
    $eventRecords | Select-Object -Last 10 | Format-Table -Property LastTimestamp, Reason, InvolvedObject, Message -AutoSize

    $eventsCsvLatest = Join-Path $ResultsDir "kubernetes-events.csv"
    $eventsCsvTimestamped = Join-Path $ResultsDir "kubernetes-events-$timestampSuffix.csv"
    $eventRecords | Export-Csv -Path $eventsCsvLatest -NoTypeInformation -Encoding UTF8
    $eventRecords | Export-Csv -Path $eventsCsvTimestamped -NoTypeInformation -Encoding UTF8
    Write-Host "  [SAVED] Events saved to: $eventsCsvLatest" -ForegroundColor Green
} else {
    Write-Host "  No events found in namespace '$Namespace'." -ForegroundColor Gray
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host " Results collection completed successfully." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
