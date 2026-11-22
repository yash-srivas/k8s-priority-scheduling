[CmdletBinding()]
param([ValidateSet('all', 'experiment-1', 'scheduling-order', 'experiment-2')][string]$ExperimentName = 'all')

. (Join-Path $PSScriptRoot 'lab-common.ps1')
$lock = $null
try {
    Assert-LabIdentity
    # Cleanup can still run when a node is NotReady, but the API must belong to the intended kind cluster.
    $lock = Enter-LabLock
    $ns = Invoke-LabKubectl @('get', 'namespace', $Namespace, '--ignore-not-found', '-o', 'name')
    if ($ns) {
        $experiments = if ($ExperimentName -eq 'all') { 'experiment-1', 'scheduling-order', 'experiment-2' } else { $ExperimentName }
        foreach ($experiment in $experiments) { Clear-LabExperiment $experiment }
    }
    Write-Host '[PASS] Selected lab workloads cleaned up.'
} catch {
    Write-Host "[FAIL] $_"
    exit 1
} finally {
    if ($lock) { $lock.ReleaseMutex(); $lock.Dispose() }
}
