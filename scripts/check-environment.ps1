# ==============================================================================
# Script: check-environment.ps1
# Description: Validates Windows environment, Docker, Minikube, and Kubernetes.
# Project: Priority-Based Pod Scheduling in Kubernetes
# ==============================================================================

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " [ENVIRONMENT PRE-FLIGHT CHECK] Kubernetes Priority Project" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Check Windows and Host RAM
$os = Get-CimInstance Win32_OperatingSystem
$totalRamGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$freeRamGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)

Write-Host "`n[1/5] Host System Resources:" -ForegroundColor Yellow
Write-Host "  - OS Name:          $($os.Caption) ($($os.Version))"
Write-Host "  - Total RAM:        $totalRamGB GB"
Write-Host "  - Free RAM:         $freeRamGB GB"

if ($totalRamGB -lt 7.0) {
    Write-Host "  [WARNING] Total RAM is less than 8 GB. Keep Minikube lightweight (e.g., 2 CPUs, 2.5GB RAM)." -ForegroundColor Yellow
} else {
    Write-Host "  [OK] Host RAM is sufficient for Minikube 2-CPU demo." -ForegroundColor Green
}

# 2. Check Docker
Write-Host "`n[2/5] Container Runtime (Docker):" -ForegroundColor Yellow
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if ($null -eq $dockerCmd) {
    Write-Host "  [FAIL] Docker CLI not found in PATH." -ForegroundColor Red
    Write-Host "         Please install Docker Desktop: https://www.docker.com/products/docker-desktop/" -ForegroundColor Yellow
} else {
    Write-Host "  - Docker CLI found at: $($dockerCmd.Source)"
    $dockerInfo = docker info 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] Docker daemon is running." -ForegroundColor Green
    } else {
        Write-Host "  [WARNING] Docker daemon is NOT running." -ForegroundColor Yellow
        Write-Host "            Please start Docker Desktop and wait until the whale icon is steady." -ForegroundColor Yellow
    }
}

# 3. Check Minikube
Write-Host "`n[3/5] Kubernetes Engine (Minikube):" -ForegroundColor Yellow
$minikubeCmd = Get-Command minikube -ErrorAction SilentlyContinue
if ($null -eq $minikubeCmd) {
    Write-Host "  [WARNING] Minikube binary not found in standard PATH." -ForegroundColor Yellow
    Write-Host "            If you have not installed Minikube yet, run:" -ForegroundColor Cyan
    Write-Host "            winget install Kubernetes.minikube" -ForegroundColor White
    Write-Host "            or download from: https://minikube.sigs.k8s.io/docs/start/" -ForegroundColor Cyan
} else {
    Write-Host "  - Minikube binary: $($minikubeCmd.Source)"
    $minikubeVer = minikube version --short 2>&1
    Write-Host "  - Minikube version: $minikubeVer"
    $minikubeStatus = minikube status 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] Minikube cluster is RUNNING." -ForegroundColor Green
    } else {
        Write-Host "  [INFO] Minikube is not running currently. Run setup.ps1 to start it." -ForegroundColor Gray
    }
}

# 4. Check kubectl
Write-Host "`n[4/5] Kubernetes CLI (kubectl):" -ForegroundColor Yellow
$kubectlCmd = Get-Command kubectl -ErrorAction SilentlyContinue
if ($null -eq $kubectlCmd) {
    Write-Host "  [FAIL] kubectl CLI not found in PATH." -ForegroundColor Red
    Write-Host "         Run: winget install Kubernetes.kubectl" -ForegroundColor Yellow
} else {
    Write-Host "  - kubectl binary: $($kubectlCmd.Source)"
    $clusterInfo = kubectl cluster-info --request-timeout=5s 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] Connected to Kubernetes cluster!" -ForegroundColor Green
        
        # 5. Check Node details
        Write-Host "`n[5/5] Kubernetes Node Diagnostics:" -ForegroundColor Yellow
        $nodesJson = kubectl get nodes -o json 2>&1 | ConvertFrom-Json
        foreach ($node in $nodesJson.items) {
            $nodeName = $node.metadata.name
            $allocCpu = $node.status.allocatable.cpu
            $allocMem = $node.status.allocatable.memory
            $statusReady = ($node.status.conditions | Where-Object { $_.type -eq "Ready" }).status
            
            Write-Host "  - Node: $nodeName | Ready: $statusReady" -ForegroundColor Cyan
            Write-Host "    Allocatable CPU:    $allocCpu"
            Write-Host "    Allocatable Memory: $allocMem"
        }

        # Check PriorityClasses
        $pc = kubectl get priorityclasses -o custom-columns=NAME:.metadata.name,VALUE:.value --no-headers 2>&1
        Write-Host "`n  Installed PriorityClasses:" -ForegroundColor Gray
        $pc | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkCyan }

        # Check Namespace
        $ns = kubectl get namespace priority-scheduling --no-headers 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] Namespace 'priority-scheduling' already exists." -ForegroundColor Green
        } else {
            Write-Host "  [INFO] Namespace 'priority-scheduling' will be created during setup." -ForegroundColor Gray
        }

    } else {
        Write-Host "  [WARNING] Unable to reach Kubernetes cluster." -ForegroundColor Yellow
        Write-Host "            If Minikube or Docker Desktop Kubernetes is stopped, please start it." -ForegroundColor Yellow
    }
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " Environment check completed." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
