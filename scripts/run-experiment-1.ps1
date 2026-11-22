[CmdletBinding()]
param([ValidateRange(5, 600)][int]$TimeoutSeconds = 120)

. (Join-Path $PSScriptRoot 'lab-common.ps1')
$experiment = 'experiment-1'
$lock = $null
$path = $null
$pods = @()
$events = @()
$expected = [ordered]@{
    'auth-service-core' = 'high'; 'payment-gateway-api' = 'high'
    'order-processing-service' = 'high'; 'emergency-telemetry-engine' = 'high'
    'frontend-web-ui-1' = 'medium'; 'frontend-web-ui-2' = 'medium'
    'inventory-service' = 'medium'; 'notification-dispatcher' = 'medium'
    'analytics-etl-worker-1' = 'low'; 'analytics-etl-worker-2' = 'low'
    'nightly-db-backup' = 'low'; 'log-compression-job' = 'low'
}
$status = 'FAIL'
$message = 'Experiment did not complete.'
$started = $false
try {
    Assert-LabIdentity
    $lock = Enter-LabLock
    Assert-LabTopology
    Assert-LabResources
    Assert-LabDemoSlot $experiment
    $path = New-LabResultPath $experiment
    Write-LabJson (Join-Path $path 'nodes.json') $LabNodes
    Write-LabJson (Join-Path $path 'priorityclasses.json') ((Get-LabJson @('get', 'priorityclasses')).items)
    Clear-LabExperiment $experiment
    $started = $true
    # Create refuses a name collision with a Pod outside the cleanup selector.
    Invoke-LabKubectl @('create', '-f', (Join-Path $ProjectRoot 'experiments/experiment-1.yaml')) | Write-Host
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $pods = @(Get-LabExperimentPods $experiment)
        $running = @($pods | Where-Object { Test-LabRunning $_ }).Count
        Write-Host "Running: $running/$($expected.Count)"
        if ($running -eq $expected.Count) { break }
        Start-Sleep -Seconds 2
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    $problems = @(foreach ($name in $expected.Keys) {
        $pod = $pods | Where-Object { $_.metadata.name -ceq $name }
        if (-not (Test-LabPriority $pod $expected[$name])) {
            "$name has the wrong class/value or is missing"
        } elseif (-not (Test-LabRunning $pod) -or $pod.spec.nodeName -cnotin $LabWorkers.metadata.name) {
            "$name on $($pod.spec.nodeName) - $(Get-LabPodProblem $pod)"
        }
    })
    Invoke-LabKubectl @('get', 'pods', '-n', $Namespace, '-o', 'wide') | Write-Host
    Invoke-LabKubectl @('describe', 'nodes') | Write-Host
    Invoke-LabKubectl @('get', 'priorityclasses') | Write-Host
    Invoke-LabKubectl @('get', 'events', '-n', $Namespace, '--sort-by=.metadata.creationTimestamp') | Write-Host
    if ($problems.Count -or $pods.Count -ne $expected.Count) {
        throw "Found $($pods.Count)/$($expected.Count) expected Pods. $($problems -join '; ')"
    }
    $status = 'PASS'
    $message = 'All 12 Pods have the expected priorities and are Running on workers. This demonstrates multi-tier priority configuration and scheduling.'
} catch {
    $status = 'FAIL'
    $message = "$_"
} finally {
    try {
        if ($started) {
            $pods = @(Get-LabExperimentPods $experiment)
            $events = @(Get-LabEvents)
            Write-LabJson (Join-Path $path 'final-pods.json') $pods
            if ($status -eq 'PASS') {
                $invalid = @($pods | Where-Object {
                    -not $expected.Contains($_.metadata.name) -or
                    -not (Test-LabPriority $_ ($expected[$_.metadata.name])) -or
                    -not (Test-LabRunning $_) -or $_.spec.nodeName -cnotin $LabWorkers.metadata.name
                })
                if ($pods.Count -ne $expected.Count -or $invalid.Count) {
                    $status = 'FAIL'
                    $message = 'Pod state changed before evidence collection. Inspect the final Pod and event CSVs.'
                }
            }
            & (Join-Path $PSScriptRoot 'collect-results.ps1') -ExperimentName $experiment -RunPath $path -Pods $pods -Events $events
        }
    } catch {
        $status = 'FAIL'
        $message += " Evidence collection failed: $_"
    }
    try { Write-LabOutcome $path $experiment $status $message @{ expected = $expected.Count; observed = $pods.Count } }
    finally { if ($lock) { $lock.ReleaseMutex(); $lock.Dispose() } }
}
if ($status -ne 'PASS') { exit 1 }
