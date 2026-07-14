# ===========================================
# Force Intune Sync via SCCM (Run Script)
# ===========================================
$LogFile = "$env:SystemRoot\Temp\IntuneSync.log"

Function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp - $Message"
    Add-Content -Path $LogFile -Value $entry
    Write-Output $entry
}

Write-Log "=== Starting Intune Sync process ==="

try {
    # 1. Restart key services
    $services = @('IntuneManagementExtension', 'dmwappushservice', 'WpnUserService')
    foreach ($svc in $services) {
        try {
            $service = Get-Service -Name $svc -ErrorAction Stop
            if ($service.Status -eq 'Running') {
                Restart-Service -Name $svc -Force -ErrorAction Stop
                Write-Log "Service $svc restarted."
            } else {
                Start-Service -Name $svc -ErrorAction Stop
                Write-Log "Service $svc started."
            }
        } catch {
            Write-Log "Service $svc not found or could not restart: $_"
        }
    }

    # 2. Run EnterpriseMgmt scheduled tasks
    $tasks = Get-ScheduledTask | Where-Object { $_.TaskPath -like '\Microsoft\Windows\EnterpriseMgmt\*' }
    if ($tasks) {
        foreach ($task in $tasks) {
            if ($task.TaskName -match 'PushLaunch|OMADMClient|Schedule') {
                try {
                    Write-Log "Running task: $($task.TaskName)"
                    Start-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName
                } catch {
                    Write-Log "Failed to start task $($task.TaskName): $_"
                }
            }
        }
    } else {
        Write-Log "No EnterpriseMgmt tasks found. Check Intune enrollment."
    }

    # 3. Trigger IME sync
    $imePaths = @(
        "${env:ProgramFiles(x86)}\Microsoft Intune Management Extension\IntuneManagementExtension.exe",
        "${env:ProgramFiles}\Microsoft Intune Management Extension\IntuneManagementExtension.exe"
    )
    $imePath = $imePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($imePath) {
        Write-Log "Starting IME sync: $imePath -sync"
        Start-Process -FilePath $imePath -ArgumentList '-sync' -WindowStyle Hidden
    } else {
        Write-Log "IME not found on this device."
    }

    Write-Log "=== Intune Sync completed successfully ==="
    exit 0
}
catch {
    Write-Log "Error during sync: $_"
    exit 1
}
