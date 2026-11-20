# ==============================================================================
# Script: cleanup.ps1
# Description: Cleans up experimental pods, namespace, and resources safely.
# Project: Priority-Based Pod Scheduling in Kubernetes
# ==============================================================================

[CmdletBinding()]
param (
    [switch]$PurgePriorityClasses,
    [switch]$PurgeCluster
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " [CLEANUP] Kubernetes Priority-Based Pod Scheduling" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$Namespace = "priority-scheduling"

# 1. Check if kubectl is available
$kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectl) {
    Write-Host "[ERROR] kubectl CLI not found." -ForegroundColor Red
    exit 1
}

# 2. Delete all pods in the namespace
Write-Host "`n[1/3] Deleting all experiment pods in '$Namespace'..." -ForegroundColor Yellow
kubectl delete pods -n $Namespace --all --grace-period=0 --force 2>&1 | Out-Null
Write-Host "  [OK] Pods deleted." -ForegroundColor Green

# 3. Delete namespace
Write-Host "`n[2/3] Deleting namespace '$Namespace'..." -ForegroundColor Yellow
$nsCheck = kubectl get namespace $Namespace --no-headers 2>&1
if ($LASTEXITCODE -eq 0) {
    kubectl delete namespace $Namespace --timeout=60s 2>&1 | Out-Null
    Write-Host "  [OK] Namespace '$Namespace' deleted." -ForegroundColor Green
} else {
    Write-Host "  Namespace '$Namespace' does not exist or was already deleted." -ForegroundColor Gray
}

# 4. Optional: Delete PriorityClasses
if ($PurgePriorityClasses) {
    Write-Host "`n[3/3] Deleting custom PriorityClasses..." -ForegroundColor Yellow
    kubectl delete priorityclass high-priority medium-priority low-priority --ignore-not-found=true 2>&1 | Out-Null
    Write-Host "  [OK] PriorityClasses removed." -ForegroundColor Green
} else {
    Write-Host "`n[3/3] Preserving PriorityClasses (high-priority, medium-priority, low-priority) for future experiments." -ForegroundColor Gray
    Write-Host "      (Pass -PurgePriorityClasses if you wish to remove them)." -ForegroundColor Gray
}

# 5. Optional Minikube purge
if ($PurgeCluster) {
    Write-Host "`n[WARNING] Purging Minikube cluster as requested by -PurgeCluster..." -ForegroundColor Red
    minikube delete
    Write-Host "  [OK] Minikube cluster deleted." -ForegroundColor Red
} else {
    Write-Host "`n[INFO] Minikube cluster and Docker remain intact." -ForegroundColor Green
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host " Cleanup completed successfully." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
