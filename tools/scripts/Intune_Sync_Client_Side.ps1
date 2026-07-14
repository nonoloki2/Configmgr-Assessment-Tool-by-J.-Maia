<#
.SYNOPSIS
  Forces a manual Intune device sync (MDM + Intune Management Extension).

.DESCRIPTION
  This script performs the equivalent of the “Sync” action from Intune by:
  - Restarting core services (IME, dmwappushservice, WpnUserService)
  - Triggering EnterpriseMgmt scheduled tasks (OMADMClient / PushLaunch)
  - Manually launching IntuneManagementExtension.exe with the “-sync” argument

.NOTES
  Run this PowerShell script with elevated privileges (Run as Administrator).
  It can be used for troubleshooting devices that are not syncing or receiving policies.

#>

# Check for Administrator privileges
If (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Error "Please run this script as Administrator."
    exit 1
}

Write-Output "=== Starting Intune Sync Process ==="

#1️⃣ Restart essential services
$servicesToRestart = @(
    'IntuneManagementExtension',   # IME - handles Win32 apps, scripts, proactive remediations
    'dmwappushservice',            # WAP Push / WNS communication service
    'WpnUserService'               # Windows Push Notification service (if it exists)
)

foreach ($svc in $servicesToRestart) {
    try {
        $s = Get-Service -Name $svc -ErrorAction Stop
        Write-Output "Restarting service: $svc (Status: $($s.Status))"
        if ($s.Status -ne 'Stopped') {
            Restart-Service -Name $svc -Force -ErrorAction Stop
        } else {
            Start-Service -Name $svc -ErrorAction Stop
        }
        Start-Sleep -Seconds 2
        Write-Output "-> Service $svc restarted successfully"
    } catch {
        Write-Warning "Service $svc not found or could not be restarted: $_"
    }
}

# 2️⃣ Locate and run EnterpriseMgmt scheduled tasks (OMADMClient / PushLaunch)
try {
    $allTasks = Get-ScheduledTask | Where-Object { $_.TaskPath -like '\Microsoft\Windows\EnterpriseMgmt\*' } -ErrorAction Stop
    if ($allTasks.Count -eq 0) {
        Write-Warning "No EnterpriseMgmt tasks found. Ensure the device is enrolled in Intune."
    } else {
        Write-Output "Found $($allTasks.Count) EnterpriseMgmt tasks. Running the relevant ones..."
        $candidates = $allTasks | Where-Object { $_.TaskName -match 'PushLaunch|OMADMClient|Schedule' }
        if ($candidates.Count -eq 0) { $candidates = $allTasks } # fallback
        foreach ($t in $candidates) {
            try {
                Write-Output "-> Running: $($t.TaskPath)$($t.TaskName)"
                Start-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName
                Start-Sleep -Seconds 1
            } catch {
                Write-Warning "Failed to start task $($t.TaskName): $_"
            }
        }
    }
} catch {
    Write-Warning "Error while enumerating scheduled tasks: $_"
}

# 3️⃣ Trigger Intune Management Extension (IME) Sync directly
$imePath = "${env:ProgramFiles(x86)}\Microsoft Intune Management Extension\IntuneManagementExtension.exe"
if (-Not (Test-Path $imePath)) {
    $imePath = "${env:ProgramFiles}\Microsoft Intune Management Extension\IntuneManagementExtension.exe"
}

if (Test-Path $imePath) {
    try {
        Write-Output "Launching IME manual sync: $imePath -sync"
        Start-Process -FilePath $imePath -ArgumentList '-sync' -WindowStyle Hidden
        Start-Sleep -Seconds 2
        Write-Output "-> IME sync triggered successfully"
    } catch {
        Write-Warning "Could not trigger IME sync: $_"
    }
} else {
    Write-Warning "Intune Management Extension not found on this device."
}

# 4️⃣ Optional: fallback check for OMADMClient actions
try {
    $tasksWithActions = $allTasks | Where-Object { $_.Actions -ne $null }
    foreach ($t in $tasksWithActions) {
        # Placeholder – Start-ScheduledTask already runs actions above
    }
} catch { }

Write-Output "=== Intune Sync Trigger Completed ==="
Write-Output "Verification steps:"
Write-Output " - IME logs: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Write-Output " - Event Viewer: Applications and Services Logs -> Microsoft -> Windows -> DeviceManagement-Enterprise-Diagnostics-Provider / Operational"
Write-Output " - Task Scheduler: Microsoft -> Windows -> EnterpriseMgmt -> {tenantId} (check Last Run Result)"
