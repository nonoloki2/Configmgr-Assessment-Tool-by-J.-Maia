#requires -version 5.1
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# --- XAML (WPF Window) ---
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Update Installer (CAB/MSU) - WPF"
        Height="360" Width="720"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResize">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" FontSize="18" FontWeight="SemiBold" Text="Windows Update Installer (CAB / MSU)" />

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
            <ProgressBar x:Name="pb" Height="20" Margin="14,2,0,0" VerticalAlignment="Center" Width="380" Minimum="0" Maximum="100"/>
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

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# --- Get controls ---
$txtFile  = $window.FindName("txtFile")
$btnBrowse = $window.FindName("btnBrowse")
$btnInstall = $window.FindName("btnInstall")
$btnCancel = $window.FindName("btnCancel")
$pb = $window.FindName("pb")
$txtLog = $window.FindName("txtLog")
$lblPct = $window.FindName("lblPct")

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

# Track running process (for graceful close prevention)
$script:CurrentProc = $null

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Update files (*.cab;*.msu)|*.cab;*.msu|CAB (*.cab)|*.cab|MSU (*.msu)|*.msu|All files (*.*)|*.*"
    $dlg.Multiselect = $false
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtFile.Text = $dlg.FileName
    }
})

$btnCancel.Add_Click({
    # Do not kill update mid-way by default; just close if idle
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

    # Reset UI
    $pb.Value = 0
    $lblPct.Text = ""
    Add-Log "Selected: $path"
    Add-Log "DISM log: C:\Windows\Logs\DISM\dism.log"
    Add-Log "CBS  log: C:\Windows\Logs\CBS\CBS.log"

    try {
        if ($ext -eq ".cab") {
            Set-UIBusy -Busy $true -Indeterminate $false
            Add-Log "Installing CAB using DISM (Online/Add-Package/NoRestart)..."

            # Start DISM and parse stdout for percentages
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "dism.exe"
            $psi.Arguments = "/Online /Add-Package /PackagePath:`"$path`" /NoRestart"
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow = $true

            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            $script:CurrentProc = $proc

            $null = $proc.Start()

            # Read output asynchronously-like (line by line)
            while (-not $proc.HasExited) {
                while (-not $proc.StandardOutput.EndOfStream) {
                    $line = $proc.StandardOutput.ReadLine()
                    if ($line) {
                        Add-Log $line

                        # Try match: "33.3%" or "100.0%"
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

            # Drain remaining streams
            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                if ($line) { Add-Log $line }
            }
            while (-not $proc.StandardError.EndOfStream) {
                $line = $proc.StandardError.ReadLine()
                if ($line) { Add-Log ("ERR: " + $line) }
            }

            $exit = $proc.ExitCode
            Add-Log "DISM finished. ExitCode=$exit"
            $window.Dispatcher.Invoke([action]{ $pb.Value = 100; $lblPct.Text = "100%" })

            if ($exit -eq 0) {
                [System.Windows.MessageBox]::Show("Update installed successfully (DISM ExitCode=0). Reboot may be required.", "Done", "OK", "Information") | Out-Null
            } else {
                [System.Windows.MessageBox]::Show("DISM finished with ExitCode=$exit. Check DISM/CBS logs for details.", "Finished with errors", "OK", "Warning") | Out-Null
            }
        }
        elseif ($ext -eq ".msu") {
            # WUSA doesn't give clean percent output; show indeterminate progress
            Set-UIBusy -Busy $true -Indeterminate $true
            Add-Log "Installing MSU using WUSA (/quiet /norestart)..."

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "wusa.exe"
            $psi.Arguments = "`"$path`" /quiet /norestart"
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow = $true

            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            $script:CurrentProc = $proc

            $null = $proc.Start()
            $proc.WaitForExit()

            # Capture any output
            $out = $proc.StandardOutput.ReadToEnd()
            $err = $proc.StandardError.ReadToEnd()
            if ($out) { Add-Log $out.Trim() }
            if ($err) { Add-Log ("ERR: " + $err.Trim()) }

            $exit = $proc.ExitCode
            Add-Log "WUSA finished. ExitCode=$exit"
            $window.Dispatcher.Invoke([action]{ $pb.IsIndeterminate = $false; $pb.Value = 100; $lblPct.Text = "" })

            # Note: WUSA exit codes vary; 0 usually OK, 3010 reboot required is common via MSI, WUSA can return 3010/0xBC2
            if ($exit -eq 0) {
                [System.Windows.MessageBox]::Show("Update installed successfully (WUSA ExitCode=0). Reboot may be required.", "Done", "OK", "Information") | Out-Null
            } else {
                [System.Windows.MessageBox]::Show("WUSA finished with ExitCode=$exit. Check Event Viewer and CBS log if needed.", "Finished with status", "OK", "Warning") | Out-Null
            }
        }
        else {
            [System.Windows.MessageBox]::Show("Unsupported file type: $ext (use .CAB or .MSU)", "Unsupported", "OK", "Warning") | Out-Null
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

# Show window
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