[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lab-common.ps1')
try {
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.ProductType -ne 1 -or [int]$os.BuildNumber -lt 22000) {
        throw "The lab expects Windows 11. Detected $($os.Caption) build $($os.BuildNumber)."
    }
    Write-Host "[OK] $($os.Caption), build $($os.BuildNumber)."
    Assert-LabTools
    Assert-LabIdentity
    Invoke-LabKubectl @('cluster-info') | Write-Host
    Show-LabNodes
    Assert-LabTopology
    Assert-LabResources
    Write-Host '[PASS] The Cloud Computing Lab environment is ready.'
} catch {
    Write-Host "[FAIL] $_"
    Write-Host 'Start Docker Desktop, select the intended kind context, and run setup.ps1 if setup is incomplete.'
    exit 1
}
