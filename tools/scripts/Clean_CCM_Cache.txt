# ================================
# SCCM Client Cache Cleanup Script
# ================================

# Set error handling to stop on any failure
$ErrorActionPreference = 'Stop'

# Define the SCCM cache folder path
$ccmCachePath = "$env:SystemRoot\ccmcache"

Write-Host "Starting SCCM cache cleanup process..." -ForegroundColor Cyan

# Step 1: Stop the SCCM Client Agent service
Write-Host "Stopping SCCM Client Agent service (CcmExec)..." -ForegroundColor Yellow
Stop-Service -Name CcmExec -Force -ErrorAction SilentlyContinue

# Step 2: Check if the cache folder exists
if (Test-Path $ccmCachePath) {
    Write-Host "Cache folder found at $ccmCachePath" -ForegroundColor Green

    # Step 3: Remove all contents from the cache folder
    Write-Host "Deleting all contents from the cache folder..." -ForegroundColor Yellow
    Get-ChildItem -Path $ccmCachePath -Recurse -Force | Remove-Item -Force -Recurse

    Write-Host "Cache folder successfully cleaned." -ForegroundColor Green
} else {
    Write-Host "Cache folder not found at $ccmCachePath. Skipping cleanup." -ForegroundColor Red
}

# Step 4: Restart the SCCM Client Agent service
Write-Host "Restarting SCCM Client Agent service (CcmExec)..." -ForegroundColor Yellow
Start-Service -Name CcmExec

Write-Host "SCCM cache cleanup completed." -ForegroundColor Cyan