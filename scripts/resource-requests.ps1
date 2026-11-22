function Convert-LabQuantity([string]$Value) {
    if (-not $Value) { return [decimal]0 }
    $quantity = [regex]::Match($Value, '^([+-]?(?:\d+(?:\.\d*)?|\.\d+))([eE][+-]?\d+|[numkKMGTEP]|[KMGTPE]i)?$')
    if (-not $quantity.Success) { throw "Unsupported Kubernetes resource quantity '$Value'." }
    $number = [decimal]::Parse($quantity.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    $suffix = $quantity.Groups[2].Value
    $multipliers = @{
        n = [decimal]0.000000001; u = [decimal]0.000001; m = [decimal]0.001; k = [decimal]1000
        G = [decimal]1e9; T = [decimal]1e12; P = [decimal]1e15; E = [decimal]1e18
        Ki = [decimal]1024; Mi = [decimal]1048576; Gi = [decimal]1073741824
        Ti = [decimal]1099511627776; Pi = [decimal]1125899906842624; Ei = [decimal]1152921504606846976
    }
    if ($suffix -ceq 'M') { return $number * 1000000 }
    if (-not $suffix) { return $number }
    if ($multipliers.ContainsKey($suffix)) { return $number * $multipliers[$suffix] }
    $exponent = [int]$suffix.Substring(1)
    return $number * [decimal][math]::Pow(10, $exponent)
}

function Get-LabPodRequest($Pod, [string]$Resource) {
    $app = [decimal]0
    $sidecars = [decimal]0
    $initPeak = [decimal]0
    foreach ($container in $Pod.spec.containers) {
        $app += Convert-LabQuantity $container.resources.requests.$Resource
    }
    foreach ($container in $Pod.spec.initContainers) {
        $request = Convert-LabQuantity $container.resources.requests.$Resource
        if ($container.restartPolicy -eq 'Always') {
            $sidecars += $request
            $initPeak = [math]::Max($initPeak, $sidecars)
        } else {
            $initPeak = [math]::Max($initPeak, ($sidecars + $request))
        }
    }
    $total = [math]::Max(($app + $sidecars), $initPeak)
    if ($Pod.spec.resources.requests.$Resource) {
        $total = Convert-LabQuantity $Pod.spec.resources.requests.$Resource
    }
    $allocated = [decimal]0
    foreach ($status in $Pod.status.containerStatuses) {
        $allocated += [math]::Max(
            (Convert-LabQuantity $status.allocatedResources.$Resource),
            (Convert-LabQuantity $status.resources.requests.$Resource)
        )
    }
    # Resize can temporarily leave larger requests allocated than the current spec.
    $total = [math]::Max($total, $allocated)
    return $total + (Convert-LabQuantity $Pod.spec.overhead.$Resource)
}

function Get-LabNodeBudget($Node, [object[]]$AllPods) {
    $name = $Node.metadata.name
    $bound = @($AllPods | Where-Object { $_.spec.nodeName -ceq $name -and $_.status.phase -notin 'Succeeded', 'Failed' })
    $requestedCpu = [long]0
    $requestedMemory = [long]0
    foreach ($pod in $bound) {
        $requestedCpu += [long][math]::Ceiling((Get-LabPodRequest $pod 'cpu') * 1000)
        $requestedMemory += [long][math]::Ceiling((Get-LabPodRequest $pod 'memory'))
    }
    $allocCpu = [long][math]::Floor((Convert-LabQuantity $Node.status.allocatable.cpu) * 1000)
    $allocMemory = [long][math]::Floor((Convert-LabQuantity $Node.status.allocatable.memory))
    [pscustomobject]@{
        Node = $name; Hostname = $Node.metadata.labels.'kubernetes.io/hostname'; Bound = $bound
        AllocatableCpuMilli = $allocCpu; AllocatableMemoryBytes = $allocMemory
        RequestedCpuMilli = $requestedCpu; RequestedMemoryBytes = $requestedMemory
        FreeCpuMilli = $allocCpu - $requestedCpu; FreeMemoryBytes = $allocMemory - $requestedMemory
        FreeSlots = [int]$Node.status.allocatable.pods - $bound.Count
    }
}
