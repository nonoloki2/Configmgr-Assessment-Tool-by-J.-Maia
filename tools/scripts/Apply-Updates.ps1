#requires -version 5.1
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# --- XAML (WPF Window) ---
[string]$xamlText = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Update Installer (CAB/MSU) - WPF"
        Height="420" Width="860"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResize">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" FontSize="18" FontWeight="SemiBold" Text="Windows Update Installer (CAB / MSU) - WPF" />

        <GroupBox Grid.Row="1" Header="Select update file" Margin="0,10,0,0">
            <Grid Margin="10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="txtFile" Grid.Column="0" Height="28" VerticalContentAlignment="Center" Margin="0,0,8,0"/>
                <Button x:Name="btnBrowse" Grid.Column="1" Content="Browse..." Padding="14,6" />
            </Grid>
        </GroupBox>

        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,10,0,0">
            <Button x:Name="btnInstall" Content="Install update" Padding="16,8" Width="140"/>
            <Button x:Name="btnCancel" Content="Close" Padding="16,8" Width="100" Margin="10,0,0,0"/>

            <CheckBox x:Name="chkNoRestart" Content="NoRestart" Margin="14,0,0,0" VerticalAlignment="Center" IsChecked="True"/>

            <Button x:Name="btnOpenDism" Content="Open DISM log" Padding="12,8" Width="120" Margin="14,0,0,0"/>
            <Button x:Name="btnOpenCbs" Content="Open CBS log" Padding="12,8" Width="120" Margin="10,0,0,0"/>

            <ProgressBar x:Name="pb" Height="20" Margin="14,2,0,0" VerticalAlignment="Center" Width="220" Minimum="0" Maximum="100"/>
            <TextBlock x:Name="lblPct" Margin="10,0,0,0" VerticalAlignment="Center" FontWeight="SemiBold"/>
        </StackPanel>

        <GroupBox Grid.Row="3" Header="Log" Margin="0,10,0,0">
            <Grid Margin="10">
                <TextBox x:Name="txtLog"
                         AcceptsReturn="True"
                         VerticalScrollBarVisibility="Auto"
                         HorizontalScrollBarVisibility="Auto"
                         IsReadOnly="True"
                         TextWrapping="NoWrap"/>
            </Grid>
        </GroupBox>
    </Grid>
</Window>
"@

# --- Load XAML safely ---
try {
    $stringReader = New-Object System.IO.StringReader($xamlText)
    $xmlReader = [System.Xml.XmlReader]::Create($stringReader)
    $window = [Windows.Markup.XamlReader]::Load($xmlReader)
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Falha ao carregar o XAML (WPF). Erro real:`r`n$($_.Exception.Message)",
        "XAML Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    throw
}

if (-not $window) { throw "XAML não gerou a janela (window = null)." }

# --- Get controls (and validate) ---
$txtFile     = $window.FindName("txtFile")
$btnBrowse   = $window.FindName("btnBrowse")
$btnInstall  = $window.FindName("btnInstall")
$btnCancel   = $window.FindName("btnCancel")
$chkNoRestart= $window.FindName("chkNoRestart")
$btnOpenDism = $window.FindName("btnOpenDism")
$btnOpenCbs  = $window.FindName("btnOpenCbs")
$pb          = $window.FindName("pb")
$txtLog      = $window.FindName("txtLog")
$lblPct      = $window.FindName("lblPct")

$missing = @()
foreach ($n in "txtFile","btnBrowse","btnInstall","btnCancel","chkNoRestart","btnOpenDism","btnOpenCbs","pb","txtLog","lblPct") {
    if (-not $window.FindName($n)) { $missing += $n }
}
if ($missing.Count -gt 0) {
    throw ("Controles não encontrados no XAML: " + ($missing -join ", "))
}

function Add-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $window.Dispatcher.Invoke([action]{
        $txtLog.AppendText("[$ts] $Message`r`n")
        $txtLog.ScrollToEnd()
    })
}

function Set-UIBusy {
    param([bool]$Busy, [bool]$Indeterminate = $false)
    $window.Dispatcher.Invoke([action]{
        $btnInstall.IsEnabled = -not $Busy
        $btnBrowse.IsEnabled  = -not $Busy
        $chkNoRestart.IsEnabled = -not $Busy
        $btnOpenDism.IsEnabled = $true
        $btnOpenCbs.IsEnabled  = $true

        $pb.IsIndeterminate   = $Indeterminate
        if ($Busy -and $Indeterminate) {
            $pb.Value = 0
            $lblPct.Text = ""
        }
        if (-not $Busy) {
            $pb.IsIndeterminate = $false
        }
    })
}

function Require-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-RebootPending {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
    )

    if (Test-Path $paths[0]) { return $true }
    if (Test-Path $paths[1]) { return $true }

    try {
        $p = Get-ItemProperty $paths[2] -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($null -ne $p.PendingFileRenameOperations) { return $true }
    } catch {}

    return $false
}

function Get-ExitHint {
    param([int]$ExitCode)
    switch ($ExitCode) {
        0     { "Success" }
        3010  { "Success - Reboot required (3010)" }
        2359302 { "WUSA: Update not applicable (0x00240006)" }
        default { "ExitCode=$ExitCode" }
    }
}

# Track running process
$script:CurrentProc = $null

# --- Open logs buttons ---
$btnOpenDism.Add_Click({
    $p = "C:\Windows\Logs\DISM\dism.log"
    if (Test-Path $p) { Start-Process notepad.exe $p } else { [System.Windows.MessageBox]::Show("DISM log not found: $p","Info","OK","Information") | Out-Null }
})

$btnOpenCbs.Add_Click({
    $p = "C:\Windows\Logs\CBS\CBS.log"
    if (Test-Path $p) { Start-Process notepad.exe $p } else { [System.Windows.MessageBox]::Show("CBS log not found: $p","Info","OK","Information") | Out-Null }
})

# --- Browse ---
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Update files (*.cab;*.msu)|*.cab;*.msu|CAB (*.cab)|*.cab|MSU (*.msu)|*.msu|All files (*.*)|*.*"
    $dlg.Multiselect = $false
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtFile.Text = $dlg.FileName
    }
})

# --- Close ---
$btnCancel.Add_Click({
    if ($script:CurrentProc -and -not $script:CurrentProc.HasExited) {
        [System.Windows.MessageBox]::Show(
            "An installation is still running. Please wait until it finishes.",
            "Busy",
            "OK",
            "Warning"
        ) | Out-Null
        return
    }
    $window.Close()
})

# --- Install ---
$btnInstall.Add_Click({
    if (-not (Require-Admin)) {
        [System.Windows.MessageBox]::Show(
            "Run PowerShell as Administrator to install updates.",
            "Admin required",
            "OK",
            "Error"
        ) | Out-Null
        return
    }

    $path = $txtFile.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) {
        [System.Windows.MessageBox]::Show("Select a valid .CAB or .MSU file first.", "Missing file", "OK", "Warning") | Out-Null
        return
    }

    $ext = ([IO.Path]::GetExtension($path)).ToLowerInvariant()
    $noRestart = [bool]$chkNoRestart.IsChecked

    # Reset UI
    $pb.Value = 0
    $lblPct.Text = ""
    Add-Log "Selected: $path"
    Add-Log "DISM log: C:\Windows\Logs\DISM\dism.log"
    Add-Log "CBS  log: C:\Windows\Logs\CBS\CBS.log"
    Add-Log ("NoRestart: {0}" -f $noRestart)

    try {
        if ($ext -eq ".cab") {
            Set-UIBusy -Busy $true -Indeterminate $false
            Add-Log "Installing CAB using DISM (Online/Add-Package)..."

            $args = @("/Online", "/Add-Package", "/PackagePath:`"$path`"")
            if ($noRestart) { $args += "/NoRestart" }

            # Start DISM and parse stdout for percentages
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "dism.exe"
            $psi.Arguments = ($args -join " ")
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow = $true

            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            $script:CurrentProc = $proc
            $null = $proc.Start()

            while (-not $proc.HasExited) {
                while (-not $proc.StandardOutput.EndOfStream) {
                    $line = $proc.StandardOutput.ReadLine()
                    if ($line) {
                        Add-Log $line
                        if ($line -match '(\d{1,3}(?:\.\d+)?)\s*%') {
                            $pct = [double]$Matches[1]
                            if ($pct -gt 100) { $pct = 100 }
                            $window.Dispatcher.Invoke([action]{
                                $pb.Value = $pct
                                $lblPct.Text = ("{0:N1}%" -f $pct)
                            })
                        }
                    }
                }
                Start-Sleep -Milliseconds 200
            }

            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                if ($line) { Add-Log $line }
            }
            while (-not $proc.StandardError.EndOfStream) {
                $line = $proc.StandardError.ReadLine()
                if ($line) { Add-Log ("ERR: " + $line) }
            }

            $exit = $proc.ExitCode
            Add-Log ("DISM finished. {0}" -f (Get-ExitHint -ExitCode $exit))
            $window.Dispatcher.Invoke([action]{ $pb.Value = 100; $lblPct.Text = "100%" })

            if ($exit -eq 0 -or $exit -eq 3010) {
                $msg = "Update installed successfully. " + ($(if ($exit -eq 3010) { "Reboot required." } else { "Reboot may be required." }))
                [System.Windows.MessageBox]::Show($msg, "Done", "OK", "Information") | Out-Null
            } else {
                [System.Windows.MessageBox]::Show("DISM finished with ExitCode=$exit. Check DISM/CBS logs for details.", "Finished with errors", "OK", "Warning") | Out-Null
            }
        }
        elseif ($ext -eq ".msu") {
            # WUSA doesn't give clean percent output; show indeterminate progress
            Set-UIBusy -Busy $true -Indeterminate $true
            Add-Log "Installing MSU using WUSA..."

            $wusaArgs = @("`"$path`"", "/quiet")
            if ($noRestart) { $wusaArgs += "/norestart" }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "wusa.exe"
            $psi.Arguments = ($wusaArgs -join " ")
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow = $true

            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            $script:CurrentProc = $proc

            $null = $proc.Start()
            $proc.WaitForExit()

            $out = $proc.StandardOutput.ReadToEnd()
            $err = $proc.StandardError.ReadToEnd()
            if ($out) { Add-Log $out.Trim() }
            if ($err) { Add-Log ("ERR: " + $err.Trim()) }

            $exit = $proc.ExitCode
            Add-Log ("WUSA finished. {0}" -f (Get-ExitHint -ExitCode $exit))
            $window.Dispatcher.Invoke([action]{ $pb.IsIndeterminate = $false; $pb.Value = 100; $lblPct.Text = "" })

            if ($exit -eq 0 -or $exit -eq 3010) {
                $msg = "Update installed successfully. " + ($(if ($exit -eq 3010) { "Reboot required." } else { "Reboot may be required." }))
                [System.Windows.MessageBox]::Show($msg, "Done", "OK", "Information") | Out-Null
            } else {
                [System.Windows.MessageBox]::Show("WUSA finished with ExitCode=$exit. Check Event Viewer and CBS log if needed.", "Finished with status", "OK", "Warning") | Out-Null
            }
        }
        else {
            [System.Windows.MessageBox]::Show("Unsupported file type: $ext (use .CAB or .MSU)", "Unsupported", "OK", "Warning") | Out-Null
        }

        # Reboot pending check (always)
        if (Test-RebootPending) {
            Add-Log "REBOOT PENDING detected."
            [System.Windows.MessageBox]::Show("Há REBOOT pendente após a instalação.", "Reboot Pending", "OK", "Warning") | Out-Null
        } else {
            Add-Log "No reboot pending detected."
        }
    }
    catch {
        Add-Log "EXCEPTION: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Error", "OK", "Error") | Out-Null
    }
    finally {
        $script:CurrentProc = $null
        Set-UIBusy -Busy $false
    }
})

# Prevent closing during install
$window.Add_Closing({
    if ($script:CurrentProc -and -not $script:CurrentProc.HasExited) {
        $_.Cancel = $true
        [System.Windows.MessageBox]::Show(
            "An installation is still running. Please wait until it finishes.",
            "Busy",
            "OK",
            "Warning"
        ) | Out-Null
    }
})

[void]$window.ShowDialog()