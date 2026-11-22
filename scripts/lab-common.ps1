$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Namespace = 'priority-scheduling'
$OwnerLabel = 'app.kubernetes.io/managed-by=priority-scheduling-lab'
$Priorities = @{ 'high-priority' = 100000; 'medium-priority' = 50000; 'low-priority' = 10000 }
# Use the same container provider for discovery and creation.
$env:KIND_EXPERIMENTAL_PROVIDER = 'docker'

function Invoke-LabNative {
    param([string]$Program, [string[]]$Arguments, [string]$InputJson)
    if (-not (Get-Command $Program -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "$Program was not found in PATH."
    }
    # PowerShell 5.1 can wrap native stderr as errors even on exit 0.
    $ErrorActionPreference = 'Continue'
    if ($PSBoundParameters.ContainsKey('InputJson')) {
        $output = $InputJson | & $Program @Arguments 2>&1
    } else {
        $output = & $Program @Arguments 2>&1
    }
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "$Program failed (exit $code): $($output -join [Environment]::NewLine)"
    }
    foreach ($line in $output) {
        if ($line -is [System.Management.Automation.ErrorRecord]) {
            Write-Verbose "$line"
        } else {
            [string]$line
        }
    }
}

function Invoke-LabKubectl {
    param([string[]]$Arguments, [string]$InputJson)
    $prefix = @('--context', $LabContext, '--request-timeout=15s')
    if ($PSBoundParameters.ContainsKey('InputJson')) {
        Invoke-LabNative kubectl ($prefix + $Arguments) -InputJson $InputJson
    } else {
        Invoke-LabNative kubectl ($prefix + $Arguments)
    }
}

function Get-LabJson([string[]]$Arguments) {
    Invoke-LabKubectl ($Arguments + @('-o', 'json')) | Out-String | ConvertFrom-Json
}

function Assert-LabTools {
    foreach ($tool in @('docker', 'kind', 'kubectl')) {
        if (-not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) {
            throw "$tool was not found in PATH. See the README for installation."
        }
        Write-Host "[OK] $tool is installed."
    }
    try {
        $engine = Invoke-LabNative docker @('info', '--format', '{{.OSType}}|{{.OperatingSystem}}|{{.KernelVersion}}')
    } catch {
        throw "Cannot reach the Docker daemon. Start Docker Desktop and check Docker access. $_"
    }
    if ($engine -notmatch '^linux\|Docker Desktop\|.*WSL2') {
        throw "Expected Docker Desktop Linux containers using the WSL 2 backend. Docker reported: $engine"
    }
    Write-Host '[OK] Docker Desktop Linux daemon is reachable on WSL 2.'
}

function Get-KindClusters {
    Invoke-LabNative kind @('get', 'clusters') | Where-Object { $_ -match '^[a-z0-9][a-z0-9-]*$' }
}

function Get-LabCurrentContext([switch]$AllowMissing) {
    if ($AllowMissing) {
        $config = Invoke-LabNative kubectl @('config', 'view', '-o', 'json') | Out-String | ConvertFrom-Json
        return $config.'current-context'
    }
    Invoke-LabNative kubectl @('config', 'current-context')
}

function Test-LabControlPlane($Node) {
    $labels = $Node.metadata.labels
    return ($null -ne $labels.PSObject.Properties['node-role.kubernetes.io/control-plane'] -or
            $null -ne $labels.PSObject.Properties['node-role.kubernetes.io/master'])
}

function Test-LabWorker($Node) {
    return (-not (Test-LabControlPlane $Node) -and -not $Node.spec.unschedulable -and
        @($Node.spec.taints | Where-Object { $_.effect -in 'NoSchedule', 'NoExecute' }).Count -eq 0 -and
        @($Node.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -eq 1)
}

function Assert-LabIdentity {
    $script:LabContext = $env:PRIORITY_KUBECTL_CONTEXT
    if (-not $LabContext) { $script:LabContext = Get-LabCurrentContext }
    Write-Host "Target kubectl context: $LabContext"
    if ($LabContext -cnotmatch '^kind-([a-z0-9][a-z0-9-]*)$') {
        throw "Select the intended kind context using kubectl config use-context. Current context: $LabContext"
    }
    $script:LabCluster = $Matches[1]
    if ($env:PRIORITY_KIND_CLUSTER -and $LabCluster -cne $env:PRIORITY_KIND_CLUSTER) {
        throw "Expected context kind-$env:PRIORITY_KIND_CLUSTER, found $LabContext."
    }
    if ($LabCluster -cnotin @(Get-KindClusters)) {
        throw "Context $LabContext has no matching kind cluster in Docker."
    }
    $trusted = Invoke-LabNative kind @('get', 'kubeconfig', '--name', $LabCluster) | Out-String
    $current = Invoke-LabNative kubectl @('--context', $LabContext, 'config', 'view', '--minify', '--flatten', '--raw', '-o', 'json') |
        Out-String | ConvertFrom-Json
    $cluster = $current.clusters[0].cluster
    $server = [regex]::Match($trusted, '(?m)^\s+server: (\S+)\s*$').Groups[1].Value
    $authority = [regex]::Match($trusted, '(?m)^\s+certificate-authority-data: (\S+)\s*$').Groups[1].Value
    if (-not $server -or -not $authority -or $cluster.server -cne $server -or
        $cluster.'certificate-authority-data' -cne $authority -or $cluster.'insecure-skip-tls-verify' -or
        $cluster.'proxy-url' -or $cluster.'tls-server-name') {
        throw "Kubeconfig server or TLS identity does not match Docker kind cluster '$LabCluster'. Export its kubeconfig with kind and select $LabContext."
    }
    $script:LabNodeNames = @(Invoke-LabNative kind @('get', 'nodes', '--name', $LabCluster) | Sort-Object)
}

function Assert-LabTopology([switch]$Wait) {
    if ($Wait) {
        Invoke-LabKubectl @('wait', '--for=condition=Ready', 'nodes', '--all', '--timeout=120s', '--request-timeout=130s') | Write-Host
    }
    $script:LabNodes = @((Get-LabJson @('get', 'nodes')).items)
    $names = @($LabNodes.metadata.name | Sort-Object)
    if ($LabNodeNames.Count -ne 3 -or $names.Count -ne 3 -or ($names -join ',') -cne ($LabNodeNames -join ',')) {
        throw "Expected the three Kubernetes nodes to match kind's Docker node names. kind: $LabNodeNames; Kubernetes: $names"
    }
    $control = @($LabNodes | Where-Object { Test-LabControlPlane $_ })
    $script:LabWorkers = @($LabNodes | Where-Object { Test-LabWorker $_ } | Sort-Object { $_.metadata.name })
    if ($control.Count -ne 1 -or $LabWorkers.Count -ne 2 -or
        -not ($control.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' })) {
        throw "Expected one Ready control plane and two Ready, uncordoned workers without blocking taints. Found $($control.Count) control-plane node(s), $($LabWorkers.Count) eligible worker(s)."
    }
    Write-Host "[OK] Verified $LabContext with one Ready control plane and two schedulable Ready workers."
}

function Show-LabNodes {
    Invoke-LabKubectl @('get', 'nodes', '-o', 'wide') | Write-Host
    Invoke-LabKubectl @('get', 'nodes', '-o', 'custom-columns=NAME:.metadata.name,CAPACITY_CPU:.status.capacity.cpu,CAPACITY_MEMORY:.status.capacity.memory,ALLOCATABLE_CPU:.status.allocatable.cpu,ALLOCATABLE_MEMORY:.status.allocatable.memory') | Write-Host
}

function Assert-LabResources {
    $projectNamespace = Get-LabJson @('get', 'namespace', $Namespace)
    if ($projectNamespace.status.phase -ne 'Active') { throw "Namespace $Namespace is not Active. Run setup.ps1." }
    Write-Host "[OK] Namespace $Namespace is Active."
    $classes = (Get-LabJson @('get', 'priorityclasses')).items
    foreach ($name in $Priorities.Keys) {
        $class = $classes | Where-Object { $_.metadata.name -eq $name }
        if (-not $class -or $class.value -ne $Priorities[$name] -or $class.globalDefault -or
            $class.preemptionPolicy -ne 'PreemptLowerPriority') {
            throw "PriorityClass '$name' is missing or has unexpected settings. Run setup.ps1."
        }
        Write-Host "[OK] $name = $($class.value), PreemptLowerPriority, globalDefault=false."
    }
}

function Enter-LabLock {
    $lock = New-Object System.Threading.Mutex($false, "Local\priority-scheduling-lab-$LabContext")
    try {
        try { $acquired = $lock.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "Another project script is changing $LabContext. Try again after it finishes." }
        return $lock
    } catch {
        $lock.Dispose()
        throw
    }
}

function Clear-LabExperiment([string]$Experiment) {
    Invoke-LabKubectl @('delete', 'pods', '-n', $Namespace, '-l', "$OwnerLabel,experiment=$Experiment",
        '--ignore-not-found=true', '--wait=true', '--timeout=60s', '--request-timeout=65s') | Write-Host
}

function Write-LabJson([string]$Path, $Value) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $json = ConvertTo-Json -InputObject $Value -Depth 35
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Assert-LabDemoSlot([string]$Experiment) {
    foreach ($other in 'experiment-1', 'scheduling-order', 'experiment-2') {
        if ($other -ne $Experiment -and @(Get-LabExperimentPods $other).Count) {
            throw "Clear $other with cleanup.ps1 -ExperimentName $other before starting $Experiment."
        }
    }
}

function Get-LabExperimentPods([string]$Experiment) {
    (Get-LabJson @('get', 'pods', '-n', $Namespace, '-l', "$OwnerLabel,experiment=$Experiment")).items
}

function Get-LabEvents {
    (Get-LabJson @('get', 'events', '-n', $Namespace, '--sort-by=.metadata.creationTimestamp')).items
}

function Test-LabRunning($Pod) {
    return ($null -ne $Pod -and $Pod.status.phase -eq 'Running' -and -not $Pod.metadata.deletionTimestamp)
}

function Test-LabPriority($Pod, [string]$Tier) {
    $class = "$Tier-priority"
    return ($null -ne $Pod -and $Pod.spec.priorityClassName -ceq $class -and $Pod.spec.priority -eq $Priorities[$class])
}

function Get-LabPodProblem($Pod) {
    if (-not $Pod) { return 'Pod missing' }
    $messages = @($Pod.status.conditions | Where-Object { $_.status -eq 'False' } | ForEach-Object { $_.message })
    $messages += @($Pod.status.containerStatuses | ForEach-Object { $_.state.waiting.message; $_.state.terminated.reason })
    "$($Pod.status.phase): $(($messages | Where-Object { $_ }) -join '; ')"
}

function Get-LabEventSource($Event) {
    if ($Event.reportingComponent) { return $Event.reportingComponent }
    return $Event.source.component
}

function New-LabResultPath([string]$Experiment) {
    $id = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    Join-Path $ProjectRoot "results/kind/$LabContext/$Experiment/$id"
}

function Write-LabOutcome([string]$Path, [string]$Experiment, [string]$Status, [string]$Message, $Details) {
    if ($Path) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        [ordered]@{
            experiment = $Experiment; context = $LabContext; status = $Status; message = $Message
            recorded_at = [DateTime]::UtcNow.ToString('o'); details = $Details
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Path 'outcome.tmp') -Encoding UTF8
        Move-Item -LiteralPath (Join-Path $Path 'outcome.tmp') -Destination (Join-Path $Path 'outcome.json')
        Write-Host "Evidence folder: $Path"
    }
    Write-Host "LAB_STATUS=$Status"
    Write-Host "[$Status] $Message"
}
