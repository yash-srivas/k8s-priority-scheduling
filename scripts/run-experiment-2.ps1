[CmdletBinding()]
param(
    [ValidateSet('Prepare', 'Equal', 'Preempt', 'Compare')][string]$Stage = 'Prepare',
    [ValidateRange(5, 600)][int]$WaitVictimsRunningSec = 120,
    [ValidateRange(5, 600)][int]$PreemptionObserveSec = 120
)

. (Join-Path $PSScriptRoot 'lab-common.ps1')
. (Join-Path $PSScriptRoot 'resource-requests.ps1')

$experiment = 'experiment-2'
$byWorker = @(
    @{ medium = 'customer-portal-api'; low = @('batch-analytics-worker-1', 'video-transcoder-node-1', 'data-crawler-job-1'); high = 'emergency-payment-surge' }
    @{ medium = 'inventory-query-service'; low = @('batch-analytics-worker-2', 'video-transcoder-node-2'); high = 'critical-order-surge' }
)
$lock = $null
$path = $null
$status = 'INCONCLUSIVE'
$message = 'No high-priority Pods were submitted.'
$submitted = $false
$runId = $null
$stageStarted = $null
$stageExecuted = $false
$rawSequence = 0
$rawSignature = ''
$observed = @{}
$lastLive = @{}
$eventCache = @{}
$baselineUids = @{}
$highUids = @{}
$confirmed = @()
$contention = @{}
$cpuFailureEvents = @{}
$probeUids = @{}
$nomination = @{}
$comparison = $null
$plan = @()

function Stop-LabScenario([string]$Message) {
    throw [InvalidOperationException]::new("Calibration: $Message")
}

function New-PreemptionPod([string]$Name, [string]$Tier, [string]$Hostname, [long]$Cpu, [switch]$EqualPriorityProbe) {
    $role = @{ low = 'victim'; medium = 'baseline'; high = 'preemptor' }[$Tier]
    if ($EqualPriorityProbe) { $role = 'equal-probe' }
    $mem = if ($Tier -eq 'high' -or $EqualPriorityProbe) { '64Mi' } else { '32Mi' }
    [ordered]@{
        apiVersion = 'v1'; kind = 'Pod'
        metadata = @{
            name = $Name; namespace = $Namespace
            labels = @{ experiment = $experiment; 'lab-run' = $runId; 'lab-stage' = $Stage.ToLowerInvariant(); tier = $Tier; role = $role; 'app.kubernetes.io/managed-by' = 'priority-scheduling-lab' }
        }
        spec = @{
            priorityClassName = "$Tier-priority"; restartPolicy = 'Never'; terminationGracePeriodSeconds = 5
            nodeSelector = @{ 'kubernetes.io/hostname' = $Hostname }
            containers = @(@{
                name = 'workload'; image = 'busybox:1.36'; command = @('sleep', '7200')
                resources = @{ requests = @{ cpu = "${Cpu}m"; memory = $mem }; limits = @{ cpu = "${Cpu}m"; memory = '96Mi' } }
            })
        }
    }
}

function Submit-LabPod($Manifest, [hashtable]$Uids) {
    Write-LabJson (Join-Path $path ($Manifest.metadata.name + '-manifest.json')) $Manifest
    Write-Host "kubectl --context $LabContext create -f - -o json [$($Manifest.metadata.name): $($Manifest.spec.priorityClassName), $($Manifest.spec.containers[0].resources.requests.cpu), $($Manifest.spec.containers[0].resources.requests.memory)]"
    $pod = Invoke-LabKubectl @('create', '-f', '-', '-o', 'json') -InputJson ($Manifest | ConvertTo-Json -Depth 12 -Compress) |
        Out-String | ConvertFrom-Json
    if (-not $pod.metadata.uid) { throw "Missing UID for $($Manifest.metadata.name) in create response." }
    $Uids[$pod.metadata.name] = $pod.metadata.uid
    $observed[$pod.metadata.uid] = $pod
    Invoke-LabKubectl @('get', 'pod', $pod.metadata.name, '-n', $Namespace, '-o', 'yaml') |
        Set-Content -LiteralPath (Join-Path $path ($pod.metadata.name + '-admitted.yaml')) -Encoding UTF8
    Write-Host "Created $($pod.metadata.name), UID $($pod.metadata.uid)"
}

function Get-SafeWorkerBudget($Node, $AllPods) {
    $budget = Get-LabNodeBudget $Node $AllPods
    $nominees = @($AllPods | Where-Object {
        -not $_.spec.nodeName -and $_.status.nominatedNodeName -ceq $budget.Node -and $_.status.phase -notin 'Succeeded', 'Failed'
    })
    if ($nominees.Count -or @($budget.Bound | Where-Object { $_.metadata.deletionTimestamp }).Count) {
        Stop-LabScenario "$($budget.Node) has nominated or terminating Pods. Wait for allocation to stabilize."
    }
    foreach ($pod in $budget.Bound) {
        if ($pod.metadata.uid -in $baselineUids.Values -or [int]$pod.spec.priority -ge $Priorities['high-priority']) { continue }
        if ($pod.metadata.namespace -notin @('kube-system', 'local-path-storage') -or
            (Get-LabPodRequest $pod 'cpu') -gt 0 -or (Get-LabPodRequest $pod 'memory') -gt 0 -or
            $pod.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution) {
            Stop-LabScenario "$($budget.Node) has an unrelated lower-priority workload ($($pod.metadata.namespace)/$($pod.metadata.name)). Use a dedicated lab cluster or clean up the other experiment first."
        }
    }
    return $budget
}

function Read-PreemptionSnapshot {
    $pods = @(Get-LabExperimentPods $experiment)
    $lastLive.Clear()
    foreach ($pod in $pods) {
        $uid = $pod.metadata.uid
        if ($uid -in $baselineUids.Values -or $uid -in $highUids.Values -or $uid -in $probeUids.Values) {
            $lastLive[$uid] = $pod
            $observed[$uid] = $pod
            if ($pod.status.nominatedNodeName) { $nomination[$uid] = $pod.status.nominatedNodeName }
            $failed = @($pod.status.conditions | Where-Object {
                $_.type -eq 'PodScheduled' -and $_.status -eq 'False' -and $_.message -match 'Insufficient cpu'
            })
            if ($uid -in $highUids.Values -and $failed.Count) { $contention[$uid] = $failed[0].message }
        }
    }
    # Persist the original API response whenever tracked event objects change.
    $raw = Invoke-LabKubectl @('get', '--raw', "/api/v1/namespaces/$Namespace/events") | Out-String
    $items = @(($raw | ConvertFrom-Json).items | Where-Object {
        $_.involvedObject.uid -in $baselineUids.Values -or $_.involvedObject.uid -in $highUids.Values -or $_.involvedObject.uid -in $probeUids.Values
    })
    $signature = ($items | ForEach-Object { "$($_.metadata.uid):$($_.metadata.resourceVersion)" } | Sort-Object) -join ','
    if ($items.Count -and $signature -cne $script:rawSignature) {
        $script:rawSignature = $signature
        $script:rawSequence++
        $sample = "events-$($Stage.ToLowerInvariant())-$($rawSequence.ToString('D3')).json"
        $target = Join-Path $path $sample
        $raw | Set-Content -LiteralPath "$target.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$target.tmp" -Destination $target
    }
    foreach ($event in $items) {
        if ($event.involvedObject.uid -in $baselineUids.Values -or $event.involvedObject.uid -in $highUids.Values -or $event.involvedObject.uid -in $probeUids.Values) {
            $eventCache[$event.metadata.uid] = $event
            if ($event.involvedObject.uid -in $highUids.Values -and $event.reason -eq 'FailedScheduling' -and
                (Get-LabEventSource $event) -eq 'default-scheduler' -and $event.message -match 'Insufficient cpu') {
                $contention[$event.involvedObject.uid] = $event.message
                $cpuFailureEvents[$event.involvedObject.uid] = $event.metadata.uid
            }
        }
    }
}

function Get-ConfirmedPreemption($Entry) {
    $preemptorUid = $highUids[$Entry.high]
    if (-not $preemptorUid) { return }
    foreach ($victimName in $Entry.low) {
        $uid = $baselineUids[$victimName]
        $victim = $lastLive[$uid]
        $disrupted = $victim.status.conditions | Where-Object {
            $_.type -eq 'DisruptionTarget' -and $_.status -eq 'True' -and $_.reason -eq 'PreemptionByScheduler'
        }
        $evidence = $eventCache.Values | Where-Object {
            $_.involvedObject.kind -eq 'Pod' -and $_.involvedObject.uid -ceq $uid -and
            $_.reason -eq 'Preempted' -and (Get-LabEventSource $_) -eq 'default-scheduler' -and
            ($_.related.uid -ceq $preemptorUid -or $_.message -match ('\b' + [regex]::Escape($preemptorUid) + '\b'))
        }
        if ($evidence -and (-not $victim -or $victim.metadata.deletionTimestamp -or $disrupted -or $victim.status.phase -eq 'Failed')) {
            $uid
        }
    }
}

function Test-PreemptionHigh($Entry) {
    $uid = $highUids[$Entry.high]
    if (-not $uid) { return $false }
    $pod = $lastLive[$uid]
    return ((Test-LabRunning $pod) -and (Test-LabPriority $pod 'high') -and $pod.spec.nodeName -ceq $Entry.node)
}

function Assert-PreemptionDisruptionBudgets {
    $budgets = (Get-LabJson @('get', 'poddisruptionbudgets', '-n', $Namespace)).items
    if ($budgets) { Stop-LabScenario "PodDisruptionBudgets in $Namespace can affect victim selection." }
}

function Get-BudgetEvidence($Budget) {
    [ordered]@{
        node = $Budget.Node; allocatableCpuMilli = $Budget.AllocatableCpuMilli
        requestedCpuMilli = $Budget.RequestedCpuMilli; freeCpuMilli = $Budget.FreeCpuMilli
        allocatableMemoryBytes = $Budget.AllocatableMemoryBytes
        requestedMemoryBytes = $Budget.RequestedMemoryBytes; freeMemoryBytes = $Budget.FreeMemoryBytes
        freePodSlots = $Budget.FreeSlots
    }
}

function Get-AllocationIdentity($Budget) {
    # Detect a changed workload or resized request between the interactive stages.
    $Budget.Bound | ForEach-Object {
        "$($_.metadata.uid)/$(Get-LabPodRequest $_ 'cpu')/$(Get-LabPodRequest $_ 'memory')"
    } | Sort-Object
}

function Read-Checkpoint([string]$Name) {
    $file = Join-Path $path $Name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Required evidence $Name is missing. Complete the preceding stage or purge the incomplete run."
    }
    Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
}

function Copy-UidMap($Object, [hashtable]$Map) {
    foreach ($entry in $Object.PSObject.Properties) { $Map[$entry.Name] = $entry.Value }
}

function Assert-RunPods([object[]]$Pods, [string[]]$ExpectedUids) {
    $actual = @($Pods | ForEach-Object { $_.metadata.uid })
    if ($actual.Count -ne $ExpectedUids.Count -or @($actual | Where-Object { $_ -cnotin $ExpectedUids }).Count) {
        throw 'The live workload set does not match this stage. Inspect the Pods or purge to start a new run.'
    }
}

function Write-StageCheckpoint([string]$File, $Evidence) {
    $target = Join-Path $path $File
    $pending = "$target.tmp"
    Write-LabJson $pending ([ordered]@{
        stage = $Stage; run_id = $runId; started_at = $stageStarted
        finished_at = [DateTime]::UtcNow.ToString('o'); evidence = $Evidence
    })
    Move-Item -LiteralPath $pending -Destination $target
}

$prepareStage = {
    Assert-PreemptionDisruptionBudgets
    $allPods = @((Get-LabJson @('get', 'pods', '-A')).items)
    for ($i = 0; $i -lt $LabWorkers.Count; $i++) {
        $node = $LabWorkers[$i]
        $entry = $byWorker[$i]
        $budget = Get-SafeWorkerBudget $node $allPods
        $count = $entry.low.Count
        $mediumCpu = [long][math]::Floor($budget.FreeCpuMilli * 0.10)
        $lowCpu = [long][math]::Floor($budget.FreeCpuMilli * 0.75 / $count)
        Write-Host "$($budget.Node): CPU allocatable/requested $($budget.AllocatableCpuMilli)m/$($budget.RequestedCpuMilli)m; memory allocatable/requested $($budget.AllocatableMemoryBytes)/$($budget.RequestedMemoryBytes) bytes; $($budget.FreeSlots) free Pod slots."
        if ($budget.FreeCpuMilli -lt 250 -or $budget.FreeMemoryBytes -lt (($count + 1) * 32MB + 64MB) -or
            $budget.FreeSlots -lt ($count + 2)) {
            Stop-LabScenario "Insufficient initial CPU, memory or Pod slots on $($budget.Node)."
        }
        if (-not $budget.Hostname -or @($LabNodes | Where-Object { $_.metadata.labels.'kubernetes.io/hostname' -ceq $budget.Hostname }).Count -ne 1) {
            Stop-LabScenario "Expected a unique kubernetes.io/hostname on $($budget.Node)."
        }
        $plan += [pscustomobject]@{
            node = $budget.Node; hostname = $budget.Hostname; medium = $entry.medium; low = $entry.low; high = $entry.high
            cpuAllocatableMilli = $budget.AllocatableCpuMilli; memoryAllocatableBytes = $budget.AllocatableMemoryBytes
            initialRequestedCpuMilli = $budget.RequestedCpuMilli; initialRequestedMemoryBytes = $budget.RequestedMemoryBytes
            mediumCpuMilli = $mediumCpu; lowCpuMilli = $lowCpu
            freeCpuBeforeHighMilli = $null; freeMemoryBeforeHighBytes = $null; highCpuMilli = $null
            before = $null; after = $null; baselineAllocations = $null; releasedVictims = @()
            requestedCpuAfterMilli = $null; freeCpuAfterMilli = $null
        }
    }

    foreach ($entry in $plan) {
        Submit-LabPod (New-PreemptionPod $entry.medium 'medium' $entry.hostname $entry.mediumCpuMilli) $baselineUids
        foreach ($name in $entry.low) {
            Submit-LabPod (New-PreemptionPod $name 'low' $entry.hostname $entry.lowCpuMilli) $baselineUids
        }
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Read-PreemptionSnapshot
        $running = @($lastLive.Values | Where-Object { Test-LabRunning $_ }).Count
        Write-Host "Baseline Running: $running/7"
        if ($running -eq 7) { break }
        Start-Sleep -Seconds 2
    } while ($timer.Elapsed.TotalSeconds -lt $WaitVictimsRunningSec)

    Assert-PreemptionDisruptionBudgets
    $allPods = @((Get-LabJson @('get', 'pods', '-A')).items)
    foreach ($entry in $plan) {
        $node = $LabWorkers | Where-Object { $_.metadata.name -ceq $entry.node }
        $budget = Get-SafeWorkerBudget $node $allPods
        $medium = $budget.Bound | Where-Object { $_.metadata.uid -ceq $baselineUids[$entry.medium] }
        if (-not (Test-LabRunning $medium) -or -not (Test-LabPriority $medium 'medium')) {
            Stop-LabScenario "$($entry.medium) is not a Running medium-priority Pod on $($entry.node). $(Get-LabPodProblem $lastLive[$baselineUids[$entry.medium]])"
        }
        $leastLowCpu = [long]::MaxValue
        foreach ($name in $entry.low) {
            $victim = $budget.Bound | Where-Object { $_.metadata.uid -ceq $baselineUids[$name] }
            if (-not (Test-LabRunning $victim) -or -not (Test-LabPriority $victim 'low')) {
                Stop-LabScenario "$name is not a Running low-priority Pod on $($entry.node). $(Get-LabPodProblem $lastLive[$baselineUids[$name]])"
            }
            $leastLowCpu = [math]::Min($leastLowCpu, [long][math]::Floor((Get-LabPodRequest $victim 'cpu') * 1000))
        }
        if ($budget.FreeCpuMilli -lt 0 -or $leastLowCpu -lt 2 -or $budget.FreeMemoryBytes -lt 64MB -or $budget.FreeSlots -lt 1) {
            Stop-LabScenario "Unable to isolate CPU contention on $($entry.node). Verify other requests, memory and Pod slots."
        }
        # One intended low Pod is enough to satisfy CPU. Zero-request infrastructure can fit again.
        $entry.before = Get-BudgetEvidence $budget
        $entry.baselineAllocations = @(Get-AllocationIdentity $budget)
        $entry.freeCpuBeforeHighMilli = $budget.FreeCpuMilli
        $entry.freeMemoryBeforeHighBytes = $budget.FreeMemoryBytes
        $entry.highCpuMilli = $budget.FreeCpuMilli + [long][math]::Ceiling($leastLowCpu / 2)
        Write-Host "$($entry.node): $($budget.FreeCpuMilli)m free; $($entry.high) needs $($entry.highCpuMilli)m; one low Pod releases at least ${leastLowCpu}m."
    }

    Write-LabJson (Join-Path $path 'baseline-pods.json') @($lastLive.Values)
    Invoke-LabKubectl @('get', 'pods', '-n', $Namespace, '-l', "$OwnerLabel,experiment=$experiment,lab-run=$runId", '-o', 'wide') | Write-Host
}

$equalStage = {
    # Same node, requests, image, scheduler, and preemption policy as the high Pod.
    # The low probe can be held Pending because it ties the lowest baseline priority.
    $target = $plan[0]
    $probeName = 'equal-priority-payment-probe'
    Submit-LabPod (New-PreemptionPod $probeName 'low' $target.hostname $target.highCpuMilli -EqualPriorityProbe) $probeUids
    $uid = $probeUids[$probeName]
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Read-PreemptionSnapshot
        $probe = $lastLive[$uid]
        $blocked = $eventCache.Values | Where-Object {
            $_.involvedObject.uid -ceq $uid -and $_.reason -eq 'FailedScheduling' -and
            (Get-LabEventSource $_) -eq 'default-scheduler' -and $_.message -match 'Insufficient cpu'
        }
        if ($probe.status.phase -eq 'Pending' -and -not $probe.spec.nodeName -and $blocked) { break }
        Start-Sleep -Seconds 2
    } while ($timer.Elapsed.TotalSeconds -lt $WaitVictimsRunningSec)
    if (-not $blocked -or $probe.status.phase -ne 'Pending' -or $probe.spec.nodeName -or
        -not (Test-LabPriority $probe 'low') -or $probe.spec.preemptionPolicy -ne 'PreemptLowerPriority' -or
        $probe.spec.schedulerName -ne 'default-scheduler' -or
        $probe.spec.nodeSelector.'kubernetes.io/hostname' -cne $target.hostname -or
        (Get-LabPodRequest $probe 'cpu') * 1000 -ne $target.highCpuMilli -or
        (Get-LabPodRequest $probe 'memory') -ne 64MB) {
        Stop-LabScenario 'The equal-priority probe did not establish the intended Pending state.'
    }
    $comparison = [ordered]@{
        node = $target.node; equalPod = $probeName; equalUid = $uid; equalPriority = $probe.spec.priority
        highPod = $target.high; highPriority = $Priorities['high-priority']; incomingCpuMilli = $target.highCpuMilli
        incomingMemory = '64Mi'; freeCpuMilli = $target.freeCpuBeforeHighMilli
        failure = @($blocked)[0].message; failureEventUid = @($blocked)[0].metadata.uid; equalPhase = $probe.status.phase; comparableBaseline = $false
    }
    Write-Host "$probeName remained Pending at priority $($probe.spec.priority): $($comparison.failure)"
    Write-LabJson (Join-Path $path 'equal-pending-pod.json') $probe
}

$removeProbe = {
    # This is the unbound comparison probe. The scheduler alone removes any baseline victim.
    $probeSelector = "$OwnerLabel,experiment=$experiment,role=equal-probe,lab-run=$runId"
    Write-Host "kubectl --context $LabContext delete pods -n $Namespace -l $probeSelector --wait=true --timeout=30s"
    Invoke-LabKubectl @('delete', 'pods', '-n', $Namespace, '-l', $probeSelector, '--wait=true', '--timeout=30s', '--request-timeout=35s') | Write-Host
}

$verifyBaseline = {
    $freshNodes = @((Get-LabJson @('get', 'nodes')).items)
    $freshPods = @((Get-LabJson @('get', 'pods', '-A')).items)
    foreach ($entry in $plan) {
        $worker = $freshNodes | Where-Object { $_.metadata.name -ceq $entry.node }
        if (-not $worker -or -not (Test-LabWorker $worker) -or $worker.metadata.labels.'kubernetes.io/hostname' -cne $entry.hostname) {
            Stop-LabScenario "Worker eligibility changed after the equal-priority probe on $($entry.node)."
        }
        $recheck = Get-SafeWorkerBudget $worker $freshPods
        $runningBaseline = @($recheck.Bound | Where-Object { $_.metadata.uid -in $baselineUids.Values -and (Test-LabRunning $_) })
        $entryNames = @($entry.low) + @($entry.medium)
        if ($recheck.AllocatableCpuMilli -ne $entry.cpuAllocatableMilli -or
            $recheck.FreeCpuMilli -ne $entry.freeCpuBeforeHighMilli -or
            $recheck.FreeMemoryBytes -ne $entry.freeMemoryBeforeHighBytes -or
            @($runningBaseline | Where-Object { $_.metadata.name -in $entryNames }).Count -ne $entryNames.Count -or
            $recheck.FreeSlots -lt 1 -or
            ((Get-AllocationIdentity $recheck) -join ';') -cne ($entry.baselineAllocations -join ';')) {
            Stop-LabScenario "The baseline changed on $($entry.node) after the equal-priority probe."
        }
    }
    Assert-PreemptionDisruptionBudgets
    Read-PreemptionSnapshot
}

$surgeStage = {
    foreach ($entry in $plan) {
        $submitted = $true
        Submit-LabPod (New-PreemptionPod $entry.high 'high' $entry.hostname $entry.highCpuMilli) $highUids
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Read-PreemptionSnapshot
        $confirmed = @(foreach ($entry in $plan) { Get-ConfirmedPreemption $entry })
        $running = @($plan | Where-Object { Test-PreemptionHigh $_ }).Count
        Write-Host "High Running: $running/2; confirmed low victims: $($confirmed.Count); CPU scheduling failures: $($contention.Count)/2"
        if ($running -eq 2 -and $cpuFailureEvents.Count -eq 2 -and
            @($plan | Where-Object { @(Get-ConfirmedPreemption $_).Count -gt 0 }).Count -eq 2) { break }
        Start-Sleep -Seconds 2
    } while ($timer.Elapsed.TotalSeconds -lt $PreemptionObserveSec)

    Invoke-LabKubectl @('get', 'pods', '-n', $Namespace, '-l', "$OwnerLabel,experiment=$experiment,lab-run=$runId", '-o', 'wide') | Write-Host
    Read-PreemptionSnapshot
    Write-Host "Captured $($eventCache.Count) event objects for this run's Pod UIDs. Open the Experiment 3 Audit for the native event times."
    $confirmed = @(foreach ($entry in $plan) { Get-ConfirmedPreemption $entry })
    $finalPodsInCluster = @((Get-LabJson @('get', 'pods', '-A')).items)
    $finalNodes = @((Get-LabJson @('get', 'nodes')).items)
    foreach ($entry in $plan) {
        $worker = $finalNodes | Where-Object { $_.metadata.name -ceq $entry.node }
        if ($worker) {
            $after = Get-LabNodeBudget $worker $finalPodsInCluster
            $entry.after = Get-BudgetEvidence $after
            $entry.releasedVictims = @(foreach ($uid in $confirmed) {
                $old = $baseline | Where-Object { $_.metadata.uid -ceq $uid -and $_.spec.nodeName -ceq $entry.node }
                if ($old -and $uid -notin @($after.Bound | ForEach-Object { $_.metadata.uid })) {
                    [ordered]@{
                        uid = $uid; name = $old.metadata.name; node = $entry.node
                        cpuMilli = [long][math]::Ceiling((Get-LabPodRequest $old 'cpu') * 1000)
                        memoryBytes = [long][math]::Ceiling((Get-LabPodRequest $old 'memory'))
                    }
                }
            })
            $entry.requestedCpuAfterMilli = $after.RequestedCpuMilli
            $entry.freeCpuAfterMilli = $after.FreeCpuMilli
        }
    }
    $comparisonHigh = $lastLive[$highUids[$comparison.highPod]]
    $comparison.highPhase = $comparisonHigh.status.phase
    $comparison.comparableBaseline = $comparison.comparableBaseline -and $comparisonHigh -and
        $comparisonHigh.spec.preemptionPolicy -eq $probe.spec.preemptionPolicy -and
        $comparisonHigh.spec.schedulerName -eq $probe.spec.schedulerName -and
        $comparisonHigh.spec.nodeSelector.'kubernetes.io/hostname' -ceq $probe.spec.nodeSelector.'kubernetes.io/hostname' -and
        (Get-LabPodRequest $comparisonHigh 'cpu') -eq (Get-LabPodRequest $probe 'cpu') -and
        (Get-LabPodRequest $comparisonHigh 'memory') -eq (Get-LabPodRequest $probe 'memory')
    $comparison.highUid = $highUids[$comparison.highPod]
    $badHigh = @($plan | Where-Object { -not (Test-PreemptionHigh $_) })
    $badMedium = @($plan | Where-Object {
        $pod = $lastLive[$baselineUids[$_.medium]]
        -not (Test-LabRunning $pod) -or -not (Test-LabPriority $pod 'medium') -or $pod.spec.nodeName -cne $_.node
    })
    if ($badHigh.Count -or $badMedium.Count) {
        $status = 'FAIL'
        $problems = @(foreach ($entry in $badHigh) { "$($entry.high): $(Get-LabPodProblem $lastLive[$highUids[$entry.high]])" })
        $problems += @(foreach ($entry in $badMedium) { "$($entry.medium): $(Get-LabPodProblem $lastLive[$baselineUids[$entry.medium]])" })
        $message = 'Expected high/medium Pod state did not hold. ' + ($problems -join '; ')
    } elseif (-not $comparison.comparableBaseline) {
        $message = 'Both high and medium Pods are Running, but the admitted high and equal probe specifications did not establish a comparable priority test.'
    } elseif (@($plan | Where-Object { -not $_.after -or -not $_.releasedVictims.Count }).Count) {
        $message = 'Placement was observed, but the final resource snapshots did not verify released requests on both workers.'
    } elseif ($cpuFailureEvents.Count -ne 2 -or @($plan | Where-Object { @(Get-ConfirmedPreemption $_).Count -gt 0 }).Count -ne 2) {
        $message = "Both high and medium Pods are Running. Proof is incomplete: native CPU scheduling failure events for $($cpuFailureEvents.Count)/2 high Pods, $($confirmed.Count) confirmed low victims."
    } else {
        $status = 'PASS'
        $message = 'The equal-priority probe stayed Pending under the same CPU shortfall. Both high Pods encountered Insufficient cpu, then ran on their planned workers. Scheduler events and actual Pod states confirm low-priority preemption on both workers. Both medium Pods are still Running.'
    }
}

try {
    Assert-LabIdentity
    $lock = Enter-LabLock
    Assert-LabTopology
    Assert-LabResources
    Assert-LabDemoSlot $experiment
    $live = @(Get-LabExperimentPods $experiment)
    $stageStarted = [DateTime]::UtcNow.ToString('o')

    if ($Stage -eq 'Prepare') {
        if ($live.Count) { throw 'An Experiment 3 run already has Pods. Purge its workloads before preparing again.' }
        $path = New-LabResultPath $experiment
        $runId = Split-Path -Leaf $path
        Write-LabJson (Join-Path $path 'nodes.json') $LabNodes
        Write-LabJson (Join-Path $path 'priorityclasses.json') ((Get-LabJson @('get', 'priorityclasses')).items)
        $stageExecuted = $true
        . $prepareStage
        Write-StageCheckpoint 'stage-prepare.json' @{ workers = $plan; baselinePodUids = $baselineUids }
        $status = 'PASS'
        $message = 'Seven baseline Pods are Running. The before snapshot is saved. Test Equal Priority when ready.'
    } else {
        $runIds = @($live | ForEach-Object { $_.metadata.labels.'lab-run' } | Select-Object -Unique)
        if ($runIds.Count -ne 1 -or $runIds[0] -cnotmatch '^\d{8}-\d{6}-\d{7}-[a-f0-9]{8}$') {
            throw 'No single staged Experiment 3 run is active. Prepare Workloads first or purge partial workloads.'
        }
        $runId = $runIds[0]
        $path = Join-Path $ProjectRoot "results/kind/$LabContext/$experiment/$runId"
        $prepared = Read-Checkpoint 'stage-prepare.json'
        if ($Stage -eq 'Compare') {
            $final = Read-Checkpoint 'outcome.json'
            if (-not (Test-Path -LiteralPath (Join-Path $path 'final-pods.json'))) {
                throw 'A final Pod snapshot is required to compare results.'
            }
            if (-not (Test-Path -LiteralPath (Join-Path $path 'stage-compare.json'))) {
                Write-StageCheckpoint 'stage-compare.json' @{ result = $final.status }
            }
            $status = 'PASS'
            $message = "Saved comparison opened. Preemption verdict: $($final.status)."
        } else {
            if (Test-Path -LiteralPath (Join-Path $path 'outcome.json')) { throw 'The preemption stage already ended. Compare or purge this run.' }
            $plan = @($prepared.evidence.workers)
            Copy-UidMap $prepared.evidence.baselinePodUids $baselineUids
            $baseline = Read-Checkpoint 'baseline-pods.json'
            Assert-RunPods $baseline @($baselineUids.Values)
            foreach ($pod in $baseline) { $observed[$pod.metadata.uid] = $pod }
            if ($Stage -eq 'Equal') {
                Assert-RunPods $live @($baselineUids.Values)
                if (Test-Path -LiteralPath (Join-Path $path 'stage-equal.json')) { throw 'The equal probe was already recorded. Purge to repeat.' }
                . $verifyBaseline
                $stageExecuted = $true
                . $equalStage
                Write-StageCheckpoint 'stage-equal.json' @{ comparison = $comparison; probePodUids = $probeUids }
                $status = 'PASS'
                $message = 'The equal-priority Pod remains Pending. Its native FailedScheduling event is saved. Trigger Preemption when ready.'
            } else {
                $equalCheckpoint = Read-Checkpoint 'stage-equal.json'
                Copy-UidMap $equalCheckpoint.evidence.probePodUids $probeUids
                Assert-RunPods $live (@($baselineUids.Values) + @($probeUids.Values))
                $probe = Read-Checkpoint 'equal-pending-pod.json'
                $observed[$probe.metadata.uid] = $probe
                $currentProbe = $live | Where-Object { $_.metadata.uid -ceq $probe.metadata.uid }
                if ($currentProbe.status.phase -ne 'Pending' -or $currentProbe.spec.nodeName -or $currentProbe.metadata.deletionTimestamp) {
                    throw 'The equal-priority probe is no longer Pending and unbound. Purge and prepare again.'
                }
                $comparison = @{}
                Copy-UidMap $equalCheckpoint.evidence.comparison $comparison
                . $verifyBaseline
                $stageExecuted = $true
                Write-StageCheckpoint 'stage-preempt-start.json' @{ workers = $plan }
                . $removeProbe
                . $verifyBaseline
                Write-LabJson (Join-Path $path 'before-preemption-pods.json') @($lastLive.Values | Where-Object { $_.metadata.uid -in $baselineUids.Values })
                $comparison.comparableBaseline = $true
                . $surgeStage
            }
        }
    }
} catch {
    $status = if ($stageExecuted -and -not $submitted -and $_.Exception.Message -like 'Calibration:*') { 'INCONCLUSIVE' } else { 'FAIL' }
    $message = "$_"
} finally {
    try {
        if ($stageExecuted -and $Stage -eq 'Preempt') {
            try {
                $finalPods = $lastLive
                if ($status -ne 'PASS') {
                    try { Read-PreemptionSnapshot } catch { $finalPods = $null; $message += " Final API snapshot unavailable: $_" }
                    $confirmed = @(foreach ($entry in $plan) { Get-ConfirmedPreemption $entry })
                }
                if ($null -ne $finalPods) { Write-LabJson (Join-Path $path 'final-pods.json') @($lastLive.Values) }
                Write-LabJson (Join-Path $path 'observed-pods.json') @($observed.Values)
                # Include the earlier equal-priority event in the CSV even after Kubernetes expires it.
                foreach ($file in (Get-ChildItem -LiteralPath $path -Filter 'events-equal-*.json')) {
                    foreach ($event in ((Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json).items)) {
                        if ($event.involvedObject.uid -in $probeUids.Values -and -not $eventCache.ContainsKey($event.metadata.uid)) {
                            $eventCache[$event.metadata.uid] = $event
                        }
                    }
                }
                $capture = @{ ExperimentName = $experiment; RunPath = $path; Pods = @($observed.Values)
                    Events = @($eventCache.Values); FinalPods = $finalPods; ConfirmedVictims = $confirmed }
                & (Join-Path $PSScriptRoot 'collect-results.ps1') @capture
            } catch {
                $status = 'FAIL'
                $message += " Evidence collection failed: $_"
            }
            Write-LabOutcome $path $experiment $status $message @{
                runId = $runId; workers = $plan; baselinePodUids = $baselineUids; highPodUids = $highUids
                confirmedVictimUids = $confirmed; cpuSchedulingFailures = $contention
                priorityComparison = $comparison; observedNominations = $nomination; cpuFailureEventUids = $cpuFailureEvents
            }
        } else {
            if ($stageExecuted -and $status -ne 'PASS') {
                Write-StageCheckpoint "failed-$($Stage.ToLowerInvariant()).json" @{ verdict = $status; message = $message }
            }
            Write-LabOutcome $null $experiment $status $message $null
        }
    } finally { if ($lock) { $lock.ReleaseMutex(); $lock.Dispose() } }
}
if ($status -eq 'INCONCLUSIVE') { exit 2 }
if ($status -ne 'PASS') { exit 1 }
