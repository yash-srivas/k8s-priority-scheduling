[CmdletBinding()]
param(
    [ValidateSet('all', 'experiment-1', 'scheduling-order', 'experiment-2')][string]$ExperimentName = 'all',
    [string]$RunPath,
    [object[]]$Pods,
    [object[]]$Events,
    [hashtable]$FinalPods,
    [string[]]$ConfirmedVictims = @()
)

. (Join-Path $PSScriptRoot 'lab-common.ps1')

if (-not $RunPath) {
    Assert-LabIdentity
    $category = if ($ExperimentName -eq 'all') { 'all' } else { "snapshot-$ExperimentName" }
    $RunPath = New-LabResultPath $category
    if ($ExperimentName -eq 'all') {
        $Pods = @((Get-LabJson @('get', 'pods', '-n', $Namespace)).items)
    } else {
        $Pods = @(Get-LabExperimentPods $ExperimentName)
    }
    $Events = @(Get-LabEvents)
}
$podRuns = @{}
foreach ($pod in $Pods) { $podRuns[$pod.metadata.uid] = $pod.metadata.labels.'lab-run' }
$uids = @($podRuns.Keys)
$eventRows = @(foreach ($event in $Events) {
    $subject = $event.involvedObject
    if ($ExperimentName -ne 'all' -and $subject.uid -notin $uids) { continue }
    $first = $event.eventTime
    if (-not $first) { $first = $event.firstTimestamp }
    if (-not $first) { $first = $event.metadata.creationTimestamp }
    $time = $event.series.lastObservedTime
    if (-not $time) { $time = $event.lastTimestamp }
    if (-not $time) { $time = $first }
    $eventRun = if ($subject.uid) { $podRuns[$subject.uid] } else { $null }
    [pscustomobject][ordered]@{
        LastTimestamp = $time; Type = $event.type; Reason = $event.reason
        InvolvedObject = "$($subject.kind)/$($subject.name)"; Message = $event.message
        Source = Get-LabEventSource $event
        PodUID = $subject.uid; RelatedUID = $event.related.uid; EventUID = $event.metadata.uid
        FirstTimestamp = $first; ResourceCreatedTimestamp = $event.metadata.creationTimestamp
        RunId = $eventRun
    }
})
$records = @(foreach ($pod in ($Pods | Sort-Object { $_.metadata.name })) {
    $uid = $pod.metadata.uid
    $phase = $pod.status.phase
    if ($null -ne $FinalPods -and -not $FinalPods.ContainsKey($uid)) { $phase = 'Deleted' }
    elseif ($pod.metadata.deletionTimestamp) { $phase = 'Terminating' }
    $scheduled = ($pod.status.conditions | Where-Object { $_.type -eq 'PodScheduled' -and $_.status -eq 'True' }).lastTransitionTime
    $started = ($pod.status.containerStatuses | Select-Object -First 1).state.running.startedAt
    $latency = if ($scheduled -and $pod.metadata.creationTimestamp) {
        [math]::Max(0, ([datetimeoffset]$scheduled - [datetimeoffset]$pod.metadata.creationTimestamp).TotalSeconds)
    } else { 'N/A' }
    $resource = ($pod.spec.containers | Select-Object -First 1).resources
    $confirmed = $uid -in $ConfirmedVictims
    $schedulerEvent = @($eventRows | Where-Object {
        $_.PodUID -eq $uid -and $_.Reason -eq 'Preempted' -and $_.Source -eq 'default-scheduler'
    }).Count -gt 0
    $disrupted = @($pod.status.conditions | Where-Object {
        $_.type -eq 'DisruptionTarget' -and $_.status -eq 'True' -and $_.reason -eq 'PreemptionByScheduler'
    }).Count -gt 0
    $preemption = if ($confirmed) { 'Confirmed' }
        elseif ($schedulerEvent -or $disrupted) { 'Scheduler evidence' }
        else { 'None' }
    [pscustomobject][ordered]@{
        PodName = $pod.metadata.name; PriorityClass = $pod.spec.priorityClassName; PriorityValue = $pod.spec.priority
        Status = $phase; Node = $pod.spec.nodeName; CpuRequest = $resource.requests.cpu; MemoryRequest = $resource.requests.memory
        CpuLimit = $resource.limits.cpu; MemoryLimit = $resource.limits.memory; CreationTime = $pod.metadata.creationTimestamp
        ScheduledTime = $scheduled; StartTime = $started; SchedulingLatencySec = $latency
        PreemptionStatus = $preemption; PodUID = $uid; Experiment = $pod.metadata.labels.experiment
        LastObservedPhase = $pod.status.phase; NominatedNode = $pod.status.nominatedNodeName; PodScheduled = if ($scheduled) { 'True' } else { ($pod.status.conditions | Where-Object type -eq PodScheduled).status }
    }
})
function Export-LabCsv($Rows, [string]$Name, [string]$Header) {
    $file = Join-Path $RunPath $Name
    if ($Rows.Count) { $Rows | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8 }
    else { Set-Content -LiteralPath $file -Value $Header -Encoding UTF8 }
}
New-Item -ItemType Directory -Path $RunPath -Force | Out-Null
$podFile = if ($ExperimentName -eq 'all') { 'all-pods-summary.csv' } else { "$ExperimentName-results.csv" }
Export-LabCsv $records $podFile 'PodName,PriorityClass,PriorityValue,Status,Node,CpuRequest,MemoryRequest,CpuLimit,MemoryLimit,CreationTime,ScheduledTime,StartTime,SchedulingLatencySec,PreemptionStatus,PodUID,Experiment,LastObservedPhase,NominatedNode,PodScheduled'
# Core/v1 Event times use UTC with optional fractional seconds. Parse the time
# so whole-second values and subsecond values in the same second sort correctly.
$chronological = @($eventRows | Sort-Object @{
    Expression = { if ($_.FirstTimestamp) { [datetimeoffset]$_.FirstTimestamp } else { [datetimeoffset]::MaxValue } }
})
Export-LabCsv $chronological 'kubernetes-events.csv' 'LastTimestamp,Type,Reason,InvolvedObject,Message,Source,PodUID,RelatedUID,EventUID,FirstTimestamp,ResourceCreatedTimestamp,RunId'
$records | Format-Table PodName, PriorityClass, PriorityValue, Status, Node, CpuRequest, MemoryRequest, PreemptionStatus -AutoSize | Out-Host
Write-Host "Collected $($records.Count) Pod rows and $($eventRows.Count) event rows in $RunPath"
if (-not $PSBoundParameters.ContainsKey('RunPath')) {
    Write-LabOutcome $RunPath $category 'PASS' 'Live snapshot exported.' $null
}
