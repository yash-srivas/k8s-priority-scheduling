[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lab-common.ps1')
$lock = $null
try {
    Assert-LabTools
    $clusters = @(Get-KindClusters)
    $current = Get-LabCurrentContext -AllowMissing
    if ($env:PRIORITY_KUBECTL_CONTEXT) {
        if ($env:PRIORITY_KUBECTL_CONTEXT -cnotmatch '^kind-([a-z0-9][a-z0-9-]*)$' -or $Matches[1] -cnotin $clusters) {
            throw 'PRIORITY_KUBECTL_CONTEXT must identify an existing Docker kind cluster. Clear it to create a cluster.'
        }
        if ($env:PRIORITY_KIND_CLUSTER -and $Matches[1] -cne $env:PRIORITY_KIND_CLUSTER) {
            throw 'PRIORITY_KUBECTL_CONTEXT and PRIORITY_KIND_CLUSTER disagree.'
        }
        $current = $env:PRIORITY_KUBECTL_CONTEXT
    }
    $target = $env:PRIORITY_KIND_CLUSTER
    if (-not $target -and $current -cmatch '^kind-([a-z0-9][a-z0-9-]*)$' -and $Matches[1] -cin $clusters) {
        $target = $Matches[1]
    }
    if (-not $target -and $clusters.Count) {
        throw "Select the intended existing kind context with kubectl config use-context. Docker kind clusters: $clusters"
    }
    if (-not $target) { $target = 'kind' }
    if ($target -cnotmatch '^[a-z0-9][a-z0-9-]*$') { throw 'Invalid PRIORITY_KIND_CLUSTER name.' }
    $LabContext = "kind-$target"
    $lock = Enter-LabLock
    if ($target -cin $clusters) {
        if ($current -cne $LabContext) { throw "Select the existing cluster with kubectl config use-context $LabContext." }
        Write-Host "Reusing existing kind cluster '$target'."
    } else {
        if ($current -and $current -cne $LabContext -and -not $env:PRIORITY_KIND_CLUSTER) {
            throw "The current context is $current. Set PRIORITY_KIND_CLUSTER explicitly to create and select a new kind cluster."
        }
        $arguments = @('create', 'cluster', '--config', (Join-Path $ProjectRoot 'kind-config.yaml'))
        if ($target -cne 'kind') { $arguments += @('--name', $target) }
        Write-Host "Creating kind cluster '$target'."
        Invoke-LabNative kind $arguments | Write-Host
    }
    Assert-LabIdentity
    Assert-LabTopology -Wait
    Invoke-LabKubectl @('apply', '-f', (Join-Path $ProjectRoot 'configs/namespace.yaml')) | Write-Host
    Invoke-LabKubectl @('apply', '-f', (Join-Path $ProjectRoot 'configs/priority-classes.yaml')) | Write-Host
    Assert-LabResources
    Show-LabNodes
    Write-Host '[PASS] Lab cluster is ready for experiments.'
} catch {
    Write-Host "[FAIL] $_"
    exit 1
} finally {
    if ($lock) { $lock.ReleaseMutex(); $lock.Dispose() }
}
