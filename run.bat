@echo off
setlocal
cd /d "%~dp0"
title K8s Priority Scheduling Lab Launcher

echo ===================================================
echo   Starting K8s Priority Scheduling Lab
echo ===================================================
echo.

:: Ensure kind and environment variables are present
set "PRIORITY_KUBECTL_CONTEXT=kind-kind"
set "PRIORITY_KIND_CLUSTER=kind"

:: Check if cluster is running
echo [1/3] Checking Kubernetes cluster...
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (-not (kind get clusters 2>$null | Select-String -Pattern '^kind$')) { Write-Host 'Cluster not found. Running setup...'; .\scripts\setup.ps1 } else { Write-Host 'Cluster is running.' }"

echo.
echo [2/3] Checking environment & context...
powershell -NoProfile -ExecutionPolicy Bypass -Command "kubectl config use-context kind-kind"

echo.
echo [3/3] Launching Flask Dashboard on http://127.0.0.1:5000...
start "" http://127.0.0.1:5000

if exist .venv\Scripts\python.exe (
    .\.venv\Scripts\python.exe dashboard\app.py
) else (
    python dashboard\app.py
)

pause
