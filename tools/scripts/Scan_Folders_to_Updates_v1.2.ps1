# Base network path where the .cab files are located
$BasePath = "\\ldcsccmfs\sccmcontent$\Updates\Top_Vulnerabilities"

# Local log file path
$LogFile = "D:\updates_log.log"

# Clear previous log (if it exists)
Clear-Content -Path $LogFile -ErrorAction SilentlyContinue

# Function to write messages to the log
function Write-Log {
    param([string]$Message)
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "$TimeStamp - $Message"
}

# Function to check if a KB is already installed
function Is-KBInstalled {
    param([string]$KBID)
    $installed = Get-HotFix | Where-Object { $_.HotFixID -eq $KBID }
    return $installed -ne $null
}

Write-Log "Starting scan in $BasePath"

# Search for all .cab files in subfolders of the network path
$CabFiles = Get-ChildItem -Path $BasePath -Recurse -Filter *.cab -ErrorAction SilentlyContinue

foreach ($Cab in $CabFiles) {
    # Try to extract KB number from filename (pattern: Windows10.0-KBxxxxxxx-x64.cab)
    $kbMatch = ($Cab.Name -match "KB\d+")
    if ($kbMatch) {
        $kb = $Matches[0]
    } else {
        $kb = "UNKNOWN"
    }

    if ($kb -ne "UNKNOWN" -and (Is-KBInstalled $kb)) {
        Write-Log "SKIPPED: $kb is already installed."
        continue
    }

    Write-Log "Attempting to install: $($Cab.FullName)"

    try {
        # Run DISM to install the .cab package
        $process = Start-Process -FilePath "dism.exe" `
            -ArgumentList "/Online /Add-Package /PackagePath:$($Cab.FullName) /Quiet /NoRestart" `
            -Wait -PassThru -ErrorAction Stop

        # Check DISM exit code
        if ($process.ExitCode -eq 0) {
            Write-Log "SUCCESS: $($Cab.Name) installed successfully."
        } else {
            Write-Log "FAILURE: $($Cab.Name) - Exit code $($process.ExitCode)."
        }
    }
    catch {
        Write-Log "ERROR: Failed to process $($Cab.Name). Details: $_"
    }
}

Write-Log "Execution finished."