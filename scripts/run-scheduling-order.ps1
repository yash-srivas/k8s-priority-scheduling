[CmdletBinding()]
param(
    [ValidateSet('Prepare', 'Release', 'Auto')][string]$Stage = 'Auto',
    [ValidateRange(20, 300)][int]$TimeoutSeconds = 90
)

. (Join-Path $PSScriptRoot 'lab-common.ps1')
. (Join-Path $PSScriptRoot 'resource-requests.ps1')

$experiment = 'scheduling-order'
$blockerName = 'order-capacity-blocker'
$lowName = 'order-low-contestant'
$highName = 'order-high-contestant'
$lock = $null
$path = $null
$status = 'FAIL'
$message = ''
$details = [ordered]@{}
$pods = @()
$events = @()
$prepared = $false
$released = $false

function New-OrderPod([string]$Name, [string]$Tier, [string]$Role, [long]$Cpu, [string]$Hostname, [string]$RunId) {
    @{
        apiVersion = 'v1'; kind = 'Pod'
        metadata = @{
            name = $Name; namespace = $Namespace
            labels = @{
                'app.kubernetes.io/managed-by' = 'priority-scheduling-lab'; experiment = 'scheduling-order'
                'lab-run' = $RunId; role = $Role; tier = $Tier
            }
        }
        spec = @{
            priorityClassName = "order-$Tier-priority"; restartPolicy = 'Never'; terminationGracePeriodSeconds = 2
            nodeSelector = @{ 'kubernetes.io/hostname' = $Hostname }
            containers = @(@{
                name = 'workload'; image = 'busybox:1.36'; command = @('sleep', '7200')
                resources = @{ requests = @{ cpu = "${Cpu}m"; memory = '32Mi' }
                    limits = @{ cpu = "${Cpu}m"; memory = '64Mi' } }
            })
        }
    }
}

function Submit-OrderPod($Manifest, [string]$Path) {
    $file = Join-Path $Path ($Manifest.metadata.name + '.json')
    Write-LabJson $file $Manifest
    Write-Host "kubectl --context $LabContext create -f `"$file`" -o json"
    Get-LabJson @('create', '-f', $file)
}

function Test-OrderPending($Pod) {
    return ($Pod.status.phase -eq 'Pending' -and -not $Pod.spec.nodeName -and
        @($Pod.status.conditions | Where-Object {
            $_.type -eq 'PodScheduled' -and $_.status -eq 'False' -and $_.message -match 'Insufficient cpu'
        }).Count -eq 1)
}

function Get-OrderObjects([string]$RunId) {
    Get-LabExperimentPods $experiment | Where-Object { $_.metadata.labels.'lab-run' -ceq $RunId }
}

function Get-OrderBudget($Worker) {
    $all = @((Get-LabJson @('get', 'pods', '-A')).items)
    if (@($all | Where-Object { $_.status.nominatedNodeName -ceq $Worker.metadata.name -and -not $_.spec.nodeName }).Count) {
        throw "A Pod is nominated on $($Worker.metadata.name). Let its placement settle before preparing the order run."
    }
    Get-LabNodeBudget $Worker $all
}

function Get-OrderCpuEvents($Events, $Uid) {
    $Events | Where-Object {
        $_.involvedObject.uid -ceq $Uid -and $_.reason -eq 'FailedScheduling' -and
        (Get-LabEventSource $_) -eq 'default-scheduler' -and $_.message -match 'Insufficient cpu'
    }
}

try {
    Assert-LabIdentity
    $lock = Enter-LabLock
    Assert-LabTopology
    Assert-LabResources
    $existing = @(Get-LabExperimentPods $experiment)
    if ($Stage -ne 'Release') {
        if (@($existing | Where-Object { $_.metadata.labels.role -eq 'blocker' }).Count) {
            throw 'A blocker is already staged. Release the slot or use cleanup -ExperimentName scheduling-order to reset.'
        }
        Assert-LabDemoSlot $experiment
        Clear-LabExperiment $experiment
        $path = New-LabResultPath $experiment
        $runId = Split-Path -Leaf $path
        Invoke-LabKubectl @('apply', '-f', (Join-Path $ProjectRoot 'configs/order-priority-classes.yaml')) | Write-Host
        foreach ($tier in 'high','low') {
            $class = Get-LabJson @('get', 'priorityclass', "order-$tier-priority")
            if ($class.preemptionPolicy -ne 'Never' -or $class.globalDefault -or $class.value -ne $Priorities["$tier-priority"]) {
                throw "Unexpected settings on order-$tier-priority."
            }
        }
        Write-LabJson (Join-Path $path 'nodes.json') $LabNodes
        Write-LabJson (Join-Path $path 'priorityclasses.json') ((Get-LabJson @('get', 'priorityclasses')).items)
        $worker = $LabWorkers[0]
        $budget = Get-OrderBudget $worker
        if (-not $budget.Hostname -or @($LabNodes | Where-Object {
            $_.metadata.labels.'kubernetes.io/hostname' -ceq $budget.Hostname
        }).Count -ne 1) { throw 'Target worker needs a unique hostname.' }
        if ($budget.FreeCpuMilli -lt 250 -or $budget.FreeMemoryBytes -lt 96MB -or $budget.FreeSlots -lt 3) {
            throw "Insufficient CPU, memory or Pod slots for the order demo on $($budget.Node)."
        }
        $blockerCpu = [long][math]::Floor($budget.FreeCpuMilli * 0.75)
        $candidateCpu = [long][math]::Floor($budget.FreeCpuMilli * 0.65)
        $details = [ordered]@{
            runId = $runId; node = $budget.Node; hostname = $budget.Hostname
            capacityCpu = $worker.status.capacity.cpu; allocatableCpuMilli = $budget.AllocatableCpuMilli
            initialRequestedCpuMilli = $budget.RequestedCpuMilli; blockerCpuMilli = $blockerCpu
            candidateCpuMilli = $candidateCpu; candidateMemory = '32Mi'; freeWithBlockerMilli = $null
        }
        Write-Host "With the blocker Running on $($budget.Node), free CPU should be $($budget.FreeCpuMilli - $blockerCpu)m. Each contestant requests ${candidateCpu}m."
        $blocker = Submit-OrderPod (New-OrderPod $blockerName 'high' 'blocker' $blockerCpu $budget.Hostname $runId) $path
        Invoke-LabKubectl @('wait', '-n', $Namespace, "--for=jsonpath={.status.phase}=Running", "pod/$blockerName",
            "--timeout=${TimeoutSeconds}s", "--request-timeout=$($TimeoutSeconds + 5)s") | Write-Host
        $low = Submit-OrderPod (New-OrderPod $lowName 'low' 'contestant' $candidateCpu $budget.Hostname $runId) $path
        # The lower priority Pod is created first and verified blocked before high is submitted.
        Invoke-LabKubectl @('wait', '-n', $Namespace, '--for=condition=PodScheduled=false', "pod/$lowName",
            "--timeout=${TimeoutSeconds}s", "--request-timeout=$($TimeoutSeconds + 5)s") | Write-Host
        Start-Sleep -Seconds 1
        $high = Submit-OrderPod (New-OrderPod $highName 'high' 'contestant' $candidateCpu $budget.Hostname $runId) $path
        $timer = [Diagnostics.Stopwatch]::StartNew()
        do {
            $pods = @(Get-OrderObjects $runId)
            $events = @(Get-LabEvents)
            $lowLive = $pods | Where-Object { $_.metadata.uid -ceq $low.metadata.uid }
            $highLive = $pods | Where-Object { $_.metadata.uid -ceq $high.metadata.uid }
            if ((Test-OrderPending $lowLive) -and (Test-OrderPending $highLive) -and
                (Get-OrderCpuEvents $events $low.metadata.uid) -and (Get-OrderCpuEvents $events $high.metadata.uid)) { break }
            Start-Sleep -Seconds 2
        } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
        if (-not ((Test-OrderPending $lowLive) -and (Test-OrderPending $highLive) -and
            (Get-OrderCpuEvents $events $low.metadata.uid) -and (Get-OrderCpuEvents $events $high.metadata.uid))) {
            throw 'Both contestants must show genuine Insufficient cpu while unbound. Inspect the Pod and event evidence.'
        }
        $details.blockerUid = $blocker.metadata.uid
        $details.lowUid = $low.metadata.uid
        $details.highUid = $high.metadata.uid
        $details.lowCreatedAt = $low.metadata.creationTimestamp
        $details.highCreatedAt = $high.metadata.creationTimestamp
        if ([datetimeoffset]$details.lowCreatedAt -ge [datetimeoffset]$details.highCreatedAt) { throw 'Pod creation order could not be established.' }
        $details.freeWithBlockerMilli = (Get-OrderBudget $worker).FreeCpuMilli
        Write-LabJson (Join-Path $path 'pending-pods.json') $pods
        Write-LabJson (Join-Path $path 'pending-events.json') @($events | Where-Object { $_.involvedObject.uid -in $pods.metadata.uid })
        Write-LabJson (Join-Path $path 'prepared.json') $details
        $prepared = $true
        Write-Host "Both contestants are Pending. Each requests ${candidateCpu}m and there is $($details.freeWithBlockerMilli)m free on $($budget.Node)."
        if ($Stage -eq 'Prepare') {
            Write-Host 'LAB_STAGE=PENDING'
            Write-Host 'Release one slot when ready. The blocker will hold its CPU requests while you inspect the Pods.'
        }
    }

    if ($Stage -ne 'Prepare') {
        if ($Stage -eq 'Release') {
            $blocker = $existing | Where-Object { $_.metadata.name -ceq $blockerName }
            $runId = $blocker.metadata.labels.'lab-run'
            if ($runId -cnotmatch '^\d{8}-\d{6}-\d{7}-[a-f0-9]{8}$') { throw 'Prepare an order run before releasing a slot.' }
            $path = Join-Path $ProjectRoot "results/kind/$LabContext/$experiment/$runId"
            $details = Get-Content -LiteralPath (Join-Path $path 'prepared.json') -Raw | ConvertFrom-Json
        }
        # Reconfirm both compete for the same slot, and give the default scheduler's
        # backoff time to elapse. A shared deletion event makes both eligible again.
        Start-Sleep -Seconds 12
        $pods = @(Get-OrderObjects $runId)
        $events = @(Get-LabEvents)
        $low = $pods | Where-Object { $_.metadata.uid -ceq $details.lowUid }
        $high = $pods | Where-Object { $_.metadata.uid -ceq $details.highUid }
        $blocker = $pods | Where-Object { $_.metadata.uid -ceq $details.blockerUid }
        $worker = $LabWorkers | Where-Object { $_.metadata.name -ceq $details.node }
        if (-not $worker -or -not (Test-LabRunning $blocker) -or -not (Test-OrderPending $low) -or -not (Test-OrderPending $high) -or
            -not (Get-OrderCpuEvents $events $details.lowUid) -or -not (Get-OrderCpuEvents $events $details.highUid)) {
            throw 'The staged Pending state changed or its events expired. Clean up scheduling-order and prepare again.'
        }
        if ($low.metadata.labels.tier -cne 'low' -or $high.metadata.labels.tier -cne 'high') {
            throw 'The expected low and high contestant identities changed.'
        }
        foreach ($candidate in @($low, $high)) {
            $tier = $candidate.metadata.labels.tier
            if ($candidate.spec.priorityClassName -cne "order-$tier-priority" -or
                $candidate.spec.priority -ne $Priorities["$tier-priority"] -or $candidate.spec.preemptionPolicy -ne 'Never' -or
                $candidate.spec.schedulerName -ne 'default-scheduler' -or
                $candidate.spec.nodeSelector.'kubernetes.io/hostname' -cne $details.hostname -or
                (Get-LabPodRequest $candidate 'cpu') * 1000 -ne $details.candidateCpuMilli -or
                (Get-LabPodRequest $candidate 'memory') -ne 32MB) { throw 'Contestant specifications no longer match the controlled comparison.' }
        }
        $budget = Get-OrderBudget $worker
        $releasedCpu = $budget.FreeCpuMilli + (Get-LabPodRequest $blocker 'cpu') * 1000
        if ($budget.FreeCpuMilli -ge $details.candidateCpuMilli -or $releasedCpu -lt $details.candidateCpuMilli -or
            $releasedCpu -ge (2 * $details.candidateCpuMilli) -or $budget.FreeMemoryBytes -lt 64MB -or $budget.FreeSlots -lt 2) {
            throw 'Current capacity no longer represents one CPU slot. Reset the order run and prepare again.'
        }
        Write-LabJson (Join-Path $path 'pre-release-pods.json') $pods
        Write-LabJson (Join-Path $path 'pre-release-events.json') @($events | Where-Object { $_.involvedObject.uid -in $pods.metadata.uid })
        $comparison = [ordered]@{
            preparation = $details; freeBeforeReleaseMilli = $budget.FreeCpuMilli; freeWithBlockerRemovedMilli = $releasedCpu
            releaseRequestedAt = [DateTime]::UtcNow.ToString('o')
        }
        $details = $comparison
        $selector = "$OwnerLabel,experiment=$experiment,role=blocker,lab-run=$runId"
        Write-Host "kubectl --context $LabContext delete pods -n $Namespace -l $selector --wait=true --timeout=30s"
        Invoke-LabKubectl @('delete', 'pods', '-n', $Namespace, '-l', $selector, '--wait=true', '--timeout=30s',
            '--request-timeout=35s') | Write-Host
        $released = $true

        $timer = [Diagnostics.Stopwatch]::StartNew()
        do {
            $live = @(Get-OrderObjects $runId)
            $events = @(Get-LabEvents)
            $low = $live | Where-Object { $_.metadata.uid -ceq $comparison.preparation.lowUid }
            $high = $live | Where-Object { $_.metadata.uid -ceq $comparison.preparation.highUid }
            $scheduled = @($events | Where-Object {
                $_.involvedObject.uid -in @($comparison.preparation.lowUid, $comparison.preparation.highUid) -and
                $_.reason -eq 'Scheduled' -and (Get-LabEventSource $_) -eq 'default-scheduler'
            })
            if ($low.spec.nodeName -or ((Test-LabRunning $high) -and $scheduled.Count)) { break }
            Start-Sleep -Seconds 2
        } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)

        $final = @{}
        foreach ($pod in $live) { $final[$pod.metadata.uid] = $pod }
        $pods = @($live) + @($blocker)
        Write-LabJson (Join-Path $path 'final-pods.json') $live
        $comparison.highNode = $high.spec.nodeName
        $comparison.lowPhase = $low.status.phase
        $comparison.highPhase = $high.status.phase
        $comparison.lowPodScheduled = @($low.status.conditions | Where-Object type -eq PodScheduled)
        $comparison.highPodScheduled = @($high.status.conditions | Where-Object type -eq PodScheduled)
        $comparison.pendingDemonstrated = $true
        $comparison.conclusion = 'One shared CPU slot was released after both contestants were observed Pending.'
        & (Join-Path $PSScriptRoot 'collect-results.ps1') -ExperimentName $experiment -RunPath $path -Pods $pods -Events $events -FinalPods $final
        $status = 'INCONCLUSIVE'
        $message = 'Both contestants had authentic CPU scheduling failures. The observed placement did not establish the expected preference.'
        if ((Test-LabRunning $high) -and $high.spec.nodeName -ceq $worker.metadata.name -and (Test-OrderPending $low) -and
            $scheduled.Count -eq 1 -and $scheduled[0].involvedObject.uid -ceq $high.metadata.uid -and
            -not ($events | Where-Object { $_.reason -eq 'Preempted' -and $_.involvedObject.uid -in $pods.metadata.uid })) {
            $status = 'PASS'
            $message = 'Low was created first. Both had identical requests and were Pending for CPU. After one slot opened, the default scheduler placed high and low remained Pending.'
        }
        Invoke-LabKubectl @('get', 'pods', '-n', $Namespace, '-l', "experiment=$experiment", '-o', 'wide') | Write-Host
    }
} catch {
    $status = if ($released) { 'INCONCLUSIVE' } else { 'FAIL' }
    $message = "$_"
    if ($path -and -not $released -and -not $prepared) {
        try {
            $pods = @(Get-LabExperimentPods $experiment)
            if ($pods.Count) { Write-LabJson (Join-Path $path 'failed-pods.json') $pods }
        } catch { Write-Host "Unable to collect a failure snapshot: $_" }
    }
} finally {
    try {
        if ($path -and $message -and ($released -or $Stage -ne 'Release')) {
            Write-LabOutcome $path $experiment $status $message $details
        } elseif ($message) {
            Write-LabOutcome $null $experiment $status $message $null
        }
    } finally {
        if ($lock) { $lock.ReleaseMutex(); $lock.Dispose() }
    }
}
if ($Stage -eq 'Prepare' -and $prepared) { return }
if ($status -eq 'INCONCLUSIVE') { exit 2 }
if ($status -ne 'PASS') { exit 1 }
