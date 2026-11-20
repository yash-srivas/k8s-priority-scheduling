# ==============================================================================
# Script: setup.ps1
# Description: Initializes Minikube cluster and configures Kubernetes PriorityClasses
# Project: Priority-Based Pod Scheduling in Kubernetes
# ==============================================================================

[CmdletBinding()]
param (
    [int]$Cpus = 2,
    [int]$MemoryMB = 3072,
    [string]$Driver = "docker"
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " [SETUP] Kubernetes Priority-Based Pod Scheduling Cluster" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigsDir = Join-Path $ProjectRoot "configs"

# 1. Check prerequisites
Write-Host "`n[Step 1/5] Checking CLI tools..." -ForegroundColor Yellow

$kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectl) {
    Write-Host "[ERROR] 'kubectl' was not found in PATH." -ForegroundColor Red
    Write-Host "Please install kubectl using: winget install Kubernetes.kubectl" -ForegroundColor Yellow
    exit 1
}
Write-Host "  [OK] kubectl found: $($kubectl.Source)" -ForegroundColor Green

$minikube = Get-Command minikube -ErrorAction SilentlyContinue
$docker = Get-Command docker -ErrorAction SilentlyContinue

# 2. Check or Start Kubernetes cluster
Write-Host "`n[Step 2/5] Checking Kubernetes Cluster..." -ForegroundColor Yellow

$clusterActive = $false
try {
    $clusterInfo = kubectl cluster-info --request-timeout=4s 2>&1
    if ($LASTEXITCODE -eq 0) {
        $clusterActive = $true
        Write-Host "  [OK] An active Kubernetes cluster is reachable!" -ForegroundColor Green
    }
} catch {
    $clusterActive = $false
}

if (-not $clusterActive) {
    if (-not $minikube) {
        Write-Host "[ERROR] Minikube is not installed and no active Kubernetes cluster was found." -ForegroundColor Red
        Write-Host "Please install Minikube using:" -ForegroundColor Yellow
        Write-Host "  winget install Kubernetes.minikube" -ForegroundColor Cyan
        Write-Host "Or enable Kubernetes in Docker Desktop Settings -> Kubernetes -> Enable Kubernetes." -ForegroundColor Cyan
        exit 1
    }

    # Verify Docker daemon is running if driver is docker
    if ($Driver -eq "docker") {
        if (-not $docker) {
            Write-Host "[ERROR] Docker is required for driver '$Driver' but docker was not found." -ForegroundColor Red
            exit 1
        }
        $dockerCheck = docker info 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] Docker Desktop is installed but the daemon is not running." -ForegroundColor Red
            Write-Host "Please start Docker Desktop application and wait for it to be ready." -ForegroundColor Yellow
            exit 1
        }
    }

    Write-Host "Starting Minikube with $Cpus CPUs, $MemoryMB MB RAM, driver '$Driver'..." -ForegroundColor Cyan
    & minikube start --cpus=$Cpus --memory="${MemoryMB}m" --driver=$Driver
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to start Minikube. Please inspect the log output above." -ForegroundColor Red
        exit 1
    }
}

# 3. Apply Namespace
Write-Host "`n[Step 3/5] Applying Project Namespace..." -ForegroundColor Yellow
$nsYaml = Join-Path $ConfigsDir "namespace.yaml"
if (Test-Path $nsYaml) {
    kubectl apply -f $nsYaml
    Write-Host "  [OK] Namespace 'priority-scheduling' ensured." -ForegroundColor Green
} else {
    Write-Host "[ERROR] Missing $nsYaml" -ForegroundColor Red
    exit 1
}

# 4. Apply PriorityClasses
Write-Host "`n[Step 4/5] Applying Kubernetes PriorityClasses..." -ForegroundColor Yellow
$pcYaml = Join-Path $ConfigsDir "priority-classes.yaml"
if (Test-Path $pcYaml) {
    kubectl apply -f $pcYaml
    Write-Host "  [OK] PriorityClasses applied successfully." -ForegroundColor Green
} else {
    Write-Host "[ERROR] Missing $pcYaml" -ForegroundColor Red
    exit 1
}

# 5. Verification
Write-Host "`n[Step 5/5] Verifying Kubernetes Configuration..." -ForegroundColor Yellow
Write-Host "`nActive PriorityClasses in cluster:" -ForegroundColor Cyan
kubectl get priorityclasses

Write-Host "`nAllocatable Resources on Nodes:" -ForegroundColor Cyan
kubectl get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,ALLOCATABLE_CPU:.status.allocatable.cpu,ALLOCATABLE_MEM:.status.allocatable.memory

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host " Setup completed successfully!" -ForegroundColor Green
Write-Host " You are now ready to run Experiment 1 and Experiment 2." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
