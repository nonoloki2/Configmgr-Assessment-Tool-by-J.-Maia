#requires -version 5.1
<#
Remediation Toolbox (DISM / Windows Update / SCCM Client / WMI)
- DISM ScanHealth / RestoreHealth
- Reset Windows Update components
- Clear CCM Cache
- MP Connectivity test (DNS + 80/443/10123)
- Reinstall SCCM Client with SMSMP= + SMSSITECODE= + /forceinstall (hidden)
- Complete CCM Client removal (CCMClean-like) + SMSCFG.ini + SMSAdvancedClient*.mif
- WMI verify/reset/rebuild

Notes:
- Designed for HTTPS client communication. Port 443 + 10123 are key.
- Logging to C:\Temp\RemediationTool\Logs\RemediationTool_*.log
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------
# Admin elevation
# -----------------------
function Test-IsAdmin {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    if (-not (Test-IsAdmin)) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $psi.Verb = "runas"
        try { [Diagnostics.Process]::Start($psi) | Out-Null } catch { }
        exit
    }
}
Ensure-Admin

# -----------------------
# Logging
# -----------------------
$BaseDir = "C:\Temp\RemediationTool"
$LogDir  = Join-Path $BaseDir "Logs"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ("RemediationTool_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile -Append | Out-Null

# -----------------------
# UI log helper
# -----------------------
function Write-UiLog {
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TextBox] $TextBox,
        [Parameter(Mandatory)] [string] $Message
    )
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $TextBox.AppendText("[$ts] $Message`r`n")
    $TextBox.SelectionStart = $TextBox.TextLength
    $TextBox.ScrollToCaret()
}

# -----------------------
# Process runner
# -----------------------
function Invoke-Exe {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string] $Arguments,
        [Parameter(Mandatory)] [System.Windows.Forms.TextBox] $UiLog
    )

    Write-UiLog $UiLog "Running: $FilePath $Arguments"
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $p.StartInfo.FileName = $FilePath
    $p.StartInfo.Arguments = $Arguments
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError  = $true
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.CreateNoWindow = $true

    $null = $p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    if ($stdout) { Write-UiLog $UiLog $stdout.TrimEnd() }
    if ($stderr) { Write-UiLog $UiLog ("STDERR: " + $stderr.TrimEnd()) }
    Write-UiLog $UiLog "ExitCode: $($p.ExitCode)"
    return $p.ExitCode
}

# -----------------------
# Health checks
# -----------------------
function Get-FreeSpaceGB {
    try {
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        return [math]::Round(($c.FreeSpace / 1GB), 2)
    } catch { return $null }
}

function Test-PendingReboot {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $true }
    }
    return $false
}

# -----------------------
# Actions: DISM
# -----------------------
function Do-DismScanHealth {
    param([System.Windows.Forms.TextBox] $UiLog)
    Invoke-Exe -FilePath "dism.exe" -Arguments "/Online /Cleanup-Image /ScanHealth" -UiLog $UiLog | Out-Null
}

function Do-DismRestoreHealth {
    param([System.Windows.Forms.TextBox] $UiLog)
    Invoke-Exe -FilePath "dism.exe" -Arguments "/Online /Cleanup-Image /RestoreHealth" -UiLog $UiLog | Out-Null
}

# -----------------------
# Actions: Windows Update reset
# -----------------------
function Do-ResetWindowsUpdateComponents {
    param([System.Windows.Forms.TextBox] $UiLog)

    Write-UiLog $UiLog "Resetting Windows Update components..."
    $services = @("wuauserv","bits","cryptsvc","msiserver","trustedinstaller")

    foreach ($svc in $services) {
        try {
            Write-UiLog $UiLog "Stopping service: $svc"
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        } catch {
            Write-UiLog $UiLog "Stop service warning ($svc): $($_.Exception.Message)"
        }
    }

    $sd  = "C:\Windows\SoftwareDistribution"
    $cr2 = "C:\Windows\System32\catroot2"

    $sdOld = "$sd.old_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
    $crOld = "$cr2.old_{0:yyyyMMdd_HHmmss}" -f (Get-Date)

    try {
        if (Test-Path $sd) {
            Write-UiLog $UiLog "Renaming $sd -> $sdOld"
            Rename-Item -Path $sd -NewName (Split-Path $sdOld -Leaf) -ErrorAction Stop
        }
    } catch { Write-UiLog $UiLog "Rename SoftwareDistribution failed: $($_.Exception.Message)" }

    try {
        if (Test-Path $cr2) {
            Write-UiLog $UiLog "Renaming $cr2 -> $crOld"
            Rename-Item -Path $cr2 -NewName (Split-Path $crOld -Leaf) -ErrorAction Stop
        }
    } catch { Write-UiLog $UiLog "Rename catroot2 failed: $($_.Exception.Message)" }

    foreach ($svc in $services) {
        try {
            Write-UiLog $UiLog "Starting service: $svc"
            Start-Service -Name $svc -ErrorAction SilentlyContinue
        } catch {
            Write-UiLog $UiLog "Start service warning ($svc): $($_.Exception.Message)"
        }
    }

    Write-UiLog $UiLog "Windows Update reset completed."
}

# -----------------------
# Actions: SCCM
# -----------------------
function Do-ClearCcmCache {
    param([System.Windows.Forms.TextBox] $UiLog)

    $cachePath = "C:\Windows\ccmcache"
    if (-not (Test-Path $cachePath)) {
        Write-UiLog $UiLog "CCM cache path not found: $cachePath"
        return
    }

    Write-UiLog $UiLog "Clearing CCM cache contents: $cachePath\* (best effort)"
    try {
        Get-ChildItem -Path $cachePath -Force -ErrorAction Stop | ForEach-Object {
            try {
                Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction Stop
            } catch {
                Write-UiLog $UiLog "Failed to remove $($_.FullName): $($_.Exception.Message)"
            }
        }
        Write-UiLog $UiLog "CCM cache cleared."
    } catch {
        Write-UiLog $UiLog "Error enumerating CCM cache: $($_.Exception.Message)"
    }
}

function Get-CcmSetupPath {
    $local = "C:\Windows\CCMSetup\ccmsetup.exe"
    if (Test-Path $local) { return $local }
    return $null
}

function Test-MpConnectivity {
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TextBox] $UiLog,
        [Parameter(Mandatory)] [string] $MpFqdn
    )

    Write-UiLog $UiLog "Connectivity tests to MP: $MpFqdn"
    Write-UiLog $UiLog "Ports: 443 (HTTPS), 10123 (Client Notification / BGB), 80 (default fallback/diagnostic)"

    # DNS check
    try {
        $dns = Resolve-DnsName -Name $MpFqdn -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1
        if ($dns) {
            Write-UiLog $UiLog "DNS OK: $MpFqdn -> $($dns.IPAddress)"
        } else {
            Write-UiLog $UiLog "DNS WARN: Resolve-DnsName returned no IP record."
        }
    } catch {
        Write-UiLog $UiLog "DNS FAIL: $MpFqdn : $($_.Exception.Message)"
    }

    $targets = @(
        @{ Name = "MP HTTPS"; Port = 443 },
        @{ Name = "SCCM Client Notification (BGB / Fast Channel)"; Port = 10123 },
        @{ Name = "MP HTTP (diagnostic)"; Port = 80 }
    )

    foreach ($t in $targets) {
        $port = [int]$t.Port
        $name = $t.Name
        try {
            $result = Test-NetConnection -ComputerName $MpFqdn -Port $port -WarningAction SilentlyContinue
            if ($result.TcpTestSucceeded) {
                Write-UiLog $UiLog "OK   - $name ($MpFqdn:$port)"
            } else {
                Write-UiLog $UiLog "FAIL - $name ($MpFqdn:$port)"
            }
        } catch {
            Write-UiLog $UiLog "ERR  - $name ($MpFqdn:$port): $($_.Exception.Message)"
        }
    }

    Write-UiLog $UiLog "Reminder: In HTTPS environments, client certificate trust issues can prevent BGB from initializing even if ports are open."
}

function Do-ReinstallSccmClient {
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TextBox] $UiLog,
        [Parameter(Mandatory)] [string] $MpFqdn,
        [Parameter(Mandatory)] [string] $SiteCode
    )

    # Run connectivity tests first (per your requirement: 443 + 10123 are key)
    Test-MpConnectivity -UiLog $UiLog -MpFqdn $MpFqdn

    $ccmsetup = Get-CcmSetupPath
    if (-not $ccmsetup) {
        Write-UiLog $UiLog "ccmsetup.exe not found in C:\Windows\CCMSetup. Select it manually."
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "ccmsetup.exe|ccmsetup.exe"
        $ofd.Title  = "Select ccmsetup.exe"
        if ($ofd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            Write-UiLog $UiLog "Reinstall canceled (ccmsetup.exe not selected)."
            return
        }
        $ccmsetup = $ofd.FileName
    }

    # Parameters:
    # - SMSMP= (forces MP)
    # - SMSSITECODE= (forces site code)
    # - /mp: (helps bootstrap to specific MP)
    # - /forceinstall always
    #
    # NOTE: We are NOT forcing /UsePKICert or other switches here to avoid unintended side effects;
    # in a PKI environment the client will use available certs. If you want /UsePKICert always,
    # tell me and I’ll hardcode it.
    $args = "SMSMP=$MpFqdn SMSSITECODE=$SiteCode /mp:$MpFqdn /forceinstall"

    Invoke-Exe -FilePath $ccmsetup -Arguments $args -UiLog $UiLog | Out-Null
    Write-UiLog $UiLog "Reinstall initiated. Check C:\Windows\CCMSetup\Logs\ccmsetup.log for progress."
}

function Do-CompleteCcmRemoval {
    param([Parameter(Mandatory)] [System.Windows.Forms.TextBox] $UiLog)

    Write-UiLog $UiLog "Starting complete CCM client removal (CCMClean-like, best effort)."

    # Stop services/processes
    $svcList = @("CcmExec","CcmSetup","smstsmgr")
    foreach ($s in $svcList) {
        try {
            $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
            if ($svc) {
                Write-UiLog $UiLog "Stopping service: $s"
                Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
            }
        } catch { Write-UiLog $UiLog "Stop service warning ($s): $($_.Exception.Message)" }
    }

    # Uninstall via ccmsetup if present
    $ccmsetup = Get-CcmSetupPath
    if ($ccmsetup) {
        Write-UiLog $UiLog "Running: ccmsetup.exe /uninstall"
        try { Invoke-Exe -FilePath $ccmsetup -Arguments "/uninstall" -UiLog $UiLog | Out-Null } catch { }
        Start-Sleep -Seconds 10
    } else {
        Write-UiLog $UiLog "ccmsetup.exe not found; proceeding with manual cleanup."
    }

    # Remove folders
    $paths = @(
        "C:\Windows\CCM",
        "C:\Windows\CCMSetup",
        "C:\Windows\ccmcache"
    )
    foreach ($p in $paths) {
        try {
            if (Test-Path $p) {
                Write-UiLog $UiLog "Removing folder: $p"
                & takeown.exe /F $p /R /D Y | Out-Null
                & icacls.exe $p /grant "*S-1-5-32-544:(OI)(CI)F" /T /C | Out-Null
                Remove-Item -Path $p -Recurse -Force -ErrorAction Stop
            }
        } catch { Write-UiLog $UiLog "Failed to remove $p: $($_.Exception.Message)" }
    }

    # Remove SMSCFG.ini (explicit)
    $smscfg = "C:\Windows\SMSCFG.ini"
    try {
        if (Test-Path $smscfg) {
            Write-UiLog $UiLog "Deleting: $smscfg"
            Remove-Item -Path $smscfg -Force -ErrorAction Stop
        }
    } catch { Write-UiLog $UiLog "Failed to delete SMSCFG.ini: $($_.Exception.Message)" }

    # Remove SMSAdvancedClient*.mif (version/KB can vary)
    try {
        Write-UiLog $UiLog "Deleting SMSAdvancedClient*.mif under C:\Windows (best effort)."
        Get-ChildItem -Path "C:\Windows" -Filter "SMSAdvancedClient*.mif" -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    Write-UiLog $UiLog "Deleting: $($_.FullName)"
                    Remove-Item -Path $_.FullName -Force -ErrorAction Stop
                } catch {
                    Write-UiLog $UiLog "Failed to delete $($_.FullName): $($_.Exception.Message)"
                }
            }
    } catch { Write-UiLog $UiLog "MIF cleanup warning: $($_.Exception.Message)" }

    # Remove registry keys
    $regKeys = @(
        "HKLM:\SOFTWARE\Microsoft\CCM",
        "HKLM:\SOFTWARE\Microsoft\CCMSetup",
        "HKLM:\SOFTWARE\Microsoft\SMS",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\CCM",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\CCMSetup",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\SMS"
    )
    foreach ($rk in $regKeys) {
        try {
            if (Test-Path $rk) {
                Write-UiLog $UiLog "Removing registry key: $rk"
                Remove-Item -Path $rk -Recurse -Force -ErrorAction Stop
            }
        } catch { Write-UiLog $UiLog "Failed to remove $rk: $($_.Exception.Message)" }
    }

    Write-UiLog $UiLog "CCM removal finished (best effort). Reboot recommended before reinstall."
}

# -----------------------
# Actions: WMI
# -----------------------
function Do-WmiVerifyRepository {
    param([System.Windows.Forms.TextBox] $UiLog)
    Invoke-Exe -FilePath "winmgmt.exe" -Arguments "/verifyrepository" -UiLog $UiLog | Out-Null
}

function Do-WmiResetRepository {
    param([System.Windows.Forms.TextBox] $UiLog)
    Invoke-Exe -FilePath "winmgmt.exe" -Arguments "/resetrepository" -UiLog $UiLog | Out-Null
}

function Do-WmiRebuildRepository {
    param([System.Windows.Forms.TextBox] $UiLog)

    Write-UiLog $UiLog "Rebuild WMI Repository (high impact)."
    Write-UiLog $UiLog "This will stop WinMgmt, rename repository, then recompile MOFs."

    # Stop WMI
    try {
        Write-UiLog $UiLog "Stopping WinMgmt..."
        Stop-Service -Name winmgmt -Force -ErrorAction SilentlyContinue
    } catch { Write-UiLog $UiLog "Stop winmgmt warning: $($_.Exception.Message)" }

    $repo = "C:\Windows\System32\wbem\Repository"
    $bak  = "$repo.bak_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
    try {
        if (Test-Path $repo) {
            Write-UiLog $UiLog "Renaming repository: $repo -> $bak"
            Rename-Item -Path $repo -NewName (Split-Path $bak -Leaf) -ErrorAction Stop
        }
    } catch { Write-UiLog $UiLog "Repository rename failed: $($_.Exception.Message)" }

    # Start WMI (it can recreate repo)
    try {
        Write-UiLog $UiLog "Starting WinMgmt..."
        Start-Service -Name winmgmt -ErrorAction SilentlyContinue
    } catch { Write-UiLog $UiLog "Start winmgmt warning: $($_.Exception.Message)" }

    Start-Sleep -Seconds 3

    # Compile MOFs (broader set, but still best-effort)
    try {
        $wbem = "C:\Windows\System32\wbem"
        Write-UiLog $UiLog "Compiling MOFs under $wbem (this can take time)..."
        Push-Location $wbem

        # Compile all *.mof in wbem (excluding some known-noisy ones is possible; leaving broad for remediation)
        Get-ChildItem -Path $wbem -Filter "*.mof" -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Invoke-Exe -FilePath "mofcomp.exe" -Arguments "`"$($_.FullName)`"" -UiLog $UiLog | Out-Null
            } catch {
                Write-UiLog $UiLog "mofcomp failed for $($_.Name): $($_.Exception.Message)"
            }
        }

        Pop-Location
    } catch { Write-UiLog $UiLog "MOF compilation warning: $($_.Exception.Message)" }

    Write-UiLog $UiLog "WMI rebuild completed (best effort). Reboot recommended."
}

# -----------------------
# GUI
# -----------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "Remediation Toolbox (DISM / WU / SCCM / WMI)"
$form.Size = New-Object System.Drawing.Size(1020, 670)
$form.StartPosition = "CenterScreen"

$btnWidth = 310
$btnHeight = 42
$leftColX = 20
$midColX  = 350
$rightColX = 680
$topY = 20
$gapY = 10

# Header label
$header = New-Object System.Windows.Forms.Label
$header.Location = New-Object System.Drawing.Point(20, 10)
$header.Size = New-Object System.Drawing.Size(960, 30)
$header.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

$free = Get-FreeSpaceGB
$pend = Test-PendingReboot
$header.Text = "Log: $LogFile   |   Free C: ${free}GB   |   Pending reboot: $pend"
$form.Controls.Add($header)

# Log TextBox
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logBox.Location = New-Object System.Drawing.Point(20, 280)
$logBox.Size = New-Object System.Drawing.Size(960, 320)
$form.Controls.Add($logBox)

function New-ActionButton {
    param(
        [string] $Text,
        [int] $X,
        [int] $Y,
        [scriptblock] $OnClick
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($btnWidth, $btnHeight)
    $b.Add_Click($OnClick)
    $form.Controls.Add($b)
    return $b
}

# 0) MP connectivity test (explicit option)
New-ActionButton "0) MP Connectivity Test (443/10123/80)" $leftColX $topY {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "MP Connectivity Test"
    $dlg.Size = New-Object System.Drawing.Size(520, 200)
    $dlg.StartPosition = "CenterParent"

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "MP FQDN:"
    $lbl.Location = New-Object System.Drawing.Point(20, 30)
    $lbl.Size = New-Object System.Drawing.Size(80, 20)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(110, 28)
    $txt.Size = New-Object System.Drawing.Size(380, 24)
    $txt.PlaceholderText = "mp01.contoso.com"

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "Test"
    $ok.Location = New-Object System.Drawing.Point(330, 110)
    $ok.Size = New-Object System.Drawing.Size(75, 30)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancel"
    $cancel.Location = New-Object System.Drawing.Point(415, 110)
    $cancel.Size = New-Object System.Drawing.Size(75, 30)

    $ok.Add_Click({
        $mp = $txt.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($mp)) {
            [System.Windows.Forms.MessageBox]::Show("Provide MP FQDN.","Missing info","OK","Warning") | Out-Null
            return
        }
        $dlg.Close()
        Test-MpConnectivity -UiLog $logBox -MpFqdn $mp
    })
    $cancel.Add_Click({ $dlg.Close() })

    $dlg.Controls.AddRange(@($lbl,$txt,$ok,$cancel))
    $dlg.ShowDialog($form) | Out-Null
} | Out-Null

# Row 1
New-ActionButton "1) DISM - ScanHealth"  $midColX $topY { Do-DismScanHealth -UiLog $logBox } | Out-Null
New-ActionButton "2) DISM - RestoreHealth" $rightColX  $topY { Do-DismRestoreHealth -UiLog $logBox } | Out-Null

# Row 2
New-ActionButton "3) Reset Windows Update Components" $leftColX ($topY+($btnHeight+$gapY)) { Do-ResetWindowsUpdateComponents -UiLog $logBox } | Out-Null
New-ActionButton "4) Clear CCM Cache" $midColX ($topY+($btnHeight+$gapY)) { Do-ClearCcmCache -UiLog $logBox } | Out-Null

# Option 5 dialog: Reinstall SCCM Agent
New-ActionButton "5) Reinstall SCCM Agent (SMSMP/SMSSITECODE)" $rightColX ($topY+($btnHeight+$gapY)) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Reinstall SCCM Agent"
    $dlg.Size = New-Object System.Drawing.Size(600, 270)
    $dlg.StartPosition = "CenterParent"

    $lblMpKey = New-Object System.Windows.Forms.Label
    $lblMpKey.Text = "SMSMP="
    $lblMpKey.Location = New-Object System.Drawing.Point(20, 30)
    $lblMpKey.Size = New-Object System.Drawing.Size(80, 20)

    $txtMpVal = New-Object System.Windows.Forms.TextBox
    $txtMpVal.Location = New-Object System.Drawing.Point(110, 28)
    $txtMpVal.Size = New-Object System.Drawing.Size(450, 24)
    $txtMpVal.PlaceholderText = "MP FQDN (e.g. mp01.contoso.com)"

    $lblSiteKey = New-Object System.Windows.Forms.Label
    $lblSiteKey.Text = "SMSSITECODE="
    $lblSiteKey.Location = New-Object System.Drawing.Point(20, 70)
    $lblSiteKey.Size = New-Object System.Drawing.Size(110, 20)

    $txtSiteVal = New-Object System.Windows.Forms.TextBox
    $txtSiteVal.Location = New-Object System.Drawing.Point(140, 68)
    $txtSiteVal.Size = New-Object System.Drawing.Size(120, 24)
    $txtSiteVal.PlaceholderText = "ABC"

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "Args used: SMSMP=<fqdn> SMSSITECODE=<code> /mp:<fqdn> /forceinstall (always)`r`nConnectivity test runs first (443 + 10123)."
    $hint.Location = New-Object System.Drawing.Point(20, 110)
    $hint.Size = New-Object System.Drawing.Size(560, 50)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "Run"
    $ok.Location = New-Object System.Drawing.Point(395, 180)
    $ok.Size = New-Object System.Drawing.Size(80, 30)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancel"
    $cancel.Location = New-Object System.Drawing.Point(480, 180)
    $cancel.Size = New-Object System.Drawing.Size(80, 30)

    $ok.Add_Click({
        $mp = $txtMpVal.Text.Trim()
        $sc = $txtSiteVal.Text.Trim().ToUpper()

        if ([string]::IsNullOrWhiteSpace($mp) -or [string]::IsNullOrWhiteSpace($sc)) {
            [System.Windows.Forms.MessageBox]::Show("Fill MP FQDN and Site Code.","Missing info","OK","Warning") | Out-Null
            return
        }
        $dlg.Close()
        Do-ReinstallSccmClient -UiLog $logBox -MpFqdn $mp -SiteCode $sc
    })

    $cancel.Add_Click({ $dlg.Close() })
    $dlg.Controls.AddRange(@($lblMpKey,$txtMpVal,$lblSiteKey,$txtSiteVal,$hint,$ok,$cancel))
    $dlg.ShowDialog($form) | Out-Null
} | Out-Null

# Row 3
New-ActionButton "6) Complete CCM Client removal (CCMClean-like)" $leftColX ($topY+2*($btnHeight+$gapY)) {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "This is destructive (CCM folders/keys + SMSCFG.ini + SMSAdvancedClient*.mif). Continue?",
        "Confirm",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        Do-CompleteCcmRemoval -UiLog $logBox
    }
} | Out-Null

New-ActionButton "7) Check WMI Consistency (verifyrepository)" $midColX ($topY+2*($btnHeight+$gapY)) {
    Do-WmiVerifyRepository -UiLog $logBox
} | Out-Null

New-ActionButton "8) Reset WMI Repository (resetrepository)" $rightColX ($topY+2*($btnHeight+$gapY)) {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Reset WMI repository can impact providers. Continue?",
        "Confirm",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        Do-WmiResetRepository -UiLog $logBox
    }
} | Out-Null

# Row 4
New-ActionButton "9) Rebuild WMI Repository (rename + mofcomp)" $leftColX ($topY+3*($btnHeight+$gapY)) {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Rebuild WMI is HIGH impact and may take time. Continue?",
        "Confirm",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        Do-WmiRebuildRepository -UiLog $logBox
    }
} | Out-Null

# Footer controls
$btnOpenLog = New-Object System.Windows.Forms.Button
$btnOpenLog.Text = "Open Log Folder"
$btnOpenLog.Location = New-Object System.Drawing.Point(20, 615-35)
$btnOpenLog.Size = New-Object System.Drawing.Size(140, 30)
$btnOpenLog.Add_Click({ Start-Process explorer.exe $LogDir | Out-Null })
$form.Controls.Add($btnOpenLog)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = "Exit"
$btnExit.Location = New-Object System.Drawing.Point(900, 615-35)
$btnExit.Size = New-Object System.Drawing.Size(80, 30)
$btnExit.Add_Click({ $form.Close() })
$form.Controls.Add($btnExit)

Write-UiLog $logBox "Tool started. Log: $LogFile"
Write-UiLog $logBox "Environment note: HTTPS client comms expected. Port 443 + 10123 should be reachable to the MP."
Write-UiLog $logBox ("Free C: {0}GB | Pending reboot: {1}" -f (Get-FreeSpaceGB), (Test-PendingReboot))

try {
    [void]$form.ShowDialog()
} finally {
    Stop-Transcript | Out-Null
}
