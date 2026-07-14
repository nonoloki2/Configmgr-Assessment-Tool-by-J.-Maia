#requires -RunAsAdministrator
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# --------------------------
# XAML (WPF UI)
# --------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="IT Toolkit (PowerShell GUI)" Height="720" Width="980"
        WindowStartupLocation="CenterScreen">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Padding="12" CornerRadius="8" Background="#1F2937">
            <DockPanel>
                <TextBlock Text="IT Toolkit" Foreground="White" FontSize="20" FontWeight="Bold" DockPanel.Dock="Left"/>
                <TextBlock Text="PowerShell GUI" Foreground="#D1D5DB" FontSize="14" VerticalAlignment="Bottom" Margin="12,0,0,0"/>
            </DockPanel>
        </Border>

        <GroupBox Grid.Row="1" Header="SCCM Client Install Parameters (Optional)" Margin="0,12,0,12">
            <Grid Margin="10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="160"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="160"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <TextBlock Grid.Column="0" Text="SMSSITECODE:" VerticalAlignment="Center"/>
                <TextBox  Grid.Column="1" Name="txtSiteCode" Height="28" Margin="6,0,18,0"/>

                <TextBlock Grid.Column="2" Text="SMSMP:" VerticalAlignment="Center"/>
                <TextBox  Grid.Column="3" Name="txtSMSMP" Height="28" Margin="6,0,0,0"/>
            </Grid>
        </GroupBox>

        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="340"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                    <TextBlock Text="Actions" FontSize="14" FontWeight="Bold" Margin="0,0,0,8"/>

                    <Button Name="btnCleanDisk" Content="Clean Disk" Height="40" Margin="0,0,0,8"/>
                    <Button Name="btnResetWU" Content="Reset Windows Update Components" Height="40" Margin="0,0,0,8"/>
                    <Button Name="btnReinstallCCM" Content="Reinstall CCM Agent (/forceinstall)" Height="40" Margin="0,0,0,8"/>
                    <Button Name="btnRebuildWMI" Content="Rebuild WMI Repository (salvage + mofcomp)" Height="40" Margin="0,0,0,8"/>
                    <Button Name="btnResetWMI" Content="Reset WMI Repository (AGGRESSIVE)" Height="40" Margin="0,0,0,8"/>
                    <Button Name="btnDISM" Content="DISM RestoreHealth" Height="40" Margin="0,0,0,8"/>
                    <Button Name="btnSFC" Content="SFC Scannow" Height="40" Margin="0,0,0,8"/>
                    <Button Name="btnDiskSpace" Content="Get Disk Free Space" Height="40" Margin="0,0,0,8"/>
                    <Button Name="btnClearCache" Content="Clear CCMCache Folder" Height="40" Margin="0,0,0,8"/>
                    <Button Name="btnInstalled" Content="Get Installed Software" Height="40" Margin="0,0,0,8"/>
                    <Button Name="btnResetPolicy" Content="Reset CCM Policies" Height="40" Margin="0,0,0,8"/>

                    <Separator Margin="0,10,0,10"/>
                    <Button Name="btnExit" Content="Exit" Height="40"/>
                </StackPanel>
            </ScrollViewer>

            <GroupBox Grid.Column="1" Header="Log" Margin="12,0,0,0">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <TextBlock Name="txtStatus" Text="Ready." Margin="0,0,0,8"/>
                    <TextBox Name="txtLog" Grid.Row="1" AcceptsReturn="True" TextWrapping="Wrap"
                             VerticalScrollBarVisibility="Auto" IsReadOnly="True"/>
                    <Button Name="btnClearLog" Grid.Row="2" Content="Clear Log" Height="34" Margin="0,8,0,0" HorizontalAlignment="Right" Width="120"/>
                </Grid>
            </GroupBox>
        </Grid>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)

# --------------------------
# Get controls
# --------------------------
function Get-Control($name) { $Window.FindName($name) }
$txtLog      = Get-Control "txtLog"
$txtStatus   = Get-Control "txtStatus"
$txtSiteCode = Get-Control "txtSiteCode"
$txtSMSMP    = Get-Control "txtSMSMP"

$btnCleanDisk   = Get-Control "btnCleanDisk"
$btnResetWU     = Get-Control "btnResetWU"
$btnReinstallCCM= Get-Control "btnReinstallCCM"
$btnRebuildWMI  = Get-Control "btnRebuildWMI"
$btnResetWMI    = Get-Control "btnResetWMI"
$btnDISM        = Get-Control "btnDISM"
$btnSFC         = Get-Control "btnSFC"
$btnDiskSpace   = Get-Control "btnDiskSpace"
$btnClearCache  = Get-Control "btnClearCache"
$btnInstalled   = Get-Control "btnInstalled"
$btnResetPolicy = Get-Control "btnResetPolicy"
$btnExit        = Get-Control "btnExit"
$btnClearLog    = Get-Control "btnClearLog"

# --------------------------
# Logging to UI
# --------------------------
function Ui-Log([string]$msg, [string]$level="INFO") {
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $level, $msg
    $txtLog.AppendText($line + [Environment]::NewLine)
    $txtLog.ScrollToEnd()
    $txtStatus.Text = $msg
}

function Run-Action([scriptblock]$action, [string]$title) {
    try {
        Ui-Log "Starting: $title"
        & $action
        Ui-Log "Finished: $title" "OK"
    } catch {
        Ui-Log ("Error in {0}: {1}" -f $title, $_.Exception.Message) "ERROR"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Error", "OK", "Error") | Out-Null
    }
}

# --------------------------
# Actions (same logic as your CLI version)
# --------------------------
function Clear-FolderContents([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}

$ActionCleanDisk = {
    $targets = @(
        $env:TEMP,
        "C:\Windows\Temp",
        "C:\Windows\Logs\CBS",
        "C:\Windows\Logs\DISM",
        "C:\ProgramData\Microsoft\Windows\WER\ReportArchive",
        "C:\ProgramData\Microsoft\Windows\WER\ReportQueue"
    )
    foreach ($t in $targets) {
        Ui-Log "Clearing: $t"
        Clear-FolderContents $t
    }
    try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue | Out-Null; Ui-Log "Recycle Bin cleared." "OK" } catch {}
}

$ActionResetWU = {
    $services = @("wuauserv","bits","cryptsvc","msiserver")
    foreach ($s in $services) { try { Stop-Service $s -Force -ErrorAction SilentlyContinue } catch {} }

    $sd  = "C:\Windows\SoftwareDistribution"
    $cat = "C:\Windows\System32\catroot2"
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    if (Test-Path $sd)  { Rename-Item $sd  ("SoftwareDistribution.old_$ts") -ErrorAction SilentlyContinue }
    if (Test-Path $cat) { Rename-Item $cat ("catroot2.old_$ts") -ErrorAction SilentlyContinue }

    foreach ($s in $services) { try { Start-Service $s -ErrorAction SilentlyContinue } catch {} }
}

$ActionReinstallCCM = {
    $ccmsetup = "C:\Windows\CCMSetup\ccmsetup.exe"
    if (-not (Test-Path $ccmsetup)) { throw "ccmsetup.exe not found at $ccmsetup" }

    $site  = $txtSiteCode.Text.Trim()
    $smsmp = $txtSMSMP.Text.Trim()

    $args = @("/forceinstall")
    if ($site)  { $args += "SMSSITECODE=$site" }
    if ($smsmp) { $args += "SMSMP=$smsmp" }

    Ui-Log ("Running: {0} {1}" -f $ccmsetup, ($args -join " "))
    & $ccmsetup @args | Out-Host
    Ui-Log "Check log: C:\Windows\CCMSetup\Logs\ccmsetup.log"
}

$ActionRebuildWMI = {
    Stop-Service winmgmt -Force -ErrorAction SilentlyContinue
    & winmgmt /salvagerepository | Out-Host
    Start-Service winmgmt -ErrorAction SilentlyContinue

    $mofPaths = @(
        "C:\Windows\System32\wbem\cimwin32.mof",
        "C:\Windows\System32\wbem\cimwin32.mfl",
        "C:\Windows\System32\wbem\wmipcima.mof",
        "C:\Windows\System32\wbem\wmipcima.mfl"
    )
    foreach ($m in $mofPaths) {
        if (Test-Path $m) { & mofcomp.exe $m | Out-Host }
    }
}

$ActionResetWMI = {
    $confirm = [System.Windows.MessageBox]::Show(
        "WARNING: WMI reset is destructive. Continue?",
        "Confirm",
        "YesNo",
        "Warning"
    )
    if ($confirm -ne "Yes") { return }

    Stop-Service winmgmt -Force -ErrorAction SilentlyContinue
    & winmgmt /resetrepository | Out-Host
    Start-Service winmgmt -ErrorAction SilentlyContinue
}

$ActionDISM = { & dism.exe /Online /Cleanup-Image /RestoreHealth | Out-Host }
$ActionSFC  = { & sfc.exe /scannow | Out-Host }

$ActionDiskSpace = {
    $drives = Get-PSDrive -PSProvider 'FileSystem' | Select-Object `
        Name,
        @{Name="FreeSpace(GB)";Expression={[math]::Round($_.Free/1GB,2)}},
        @{Name="UsedSpace(GB)";Expression={[math]::Round($_.Used/1GB,2)}},
        @{Name="TotalSize(GB)";Expression={[math]::Round(($_.Used/1GB + $_.Free/1GB),2)}}

    Ui-Log "Disk Space Information:"
    $txtLog.AppendText(($drives | Format-Table -AutoSize | Out-String) + [Environment]::NewLine)
    $txtLog.ScrollToEnd()
}

$ActionClearCache = {
    $cachePath = "C:\Windows\ccmcache"
    if (-not (Test-Path $cachePath)) { throw "CCMCache folder not found: $cachePath" }
    Clear-FolderContents $cachePath
    Ui-Log "CCMCache cleared." "OK"
}

$ActionInstalled = {
    $apps = Get-ItemProperty `
        HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*, `
        HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
        Where-Object { $_.DisplayName -ne $null } |
        Sort-Object DisplayName

    Ui-Log "Installed Software:"
    $txtLog.AppendText(($apps | Format-Table -AutoSize | Out-String) + [Environment]::NewLine)
    $txtLog.ScrollToEnd()
}

$ActionResetPolicy = {
    Ui-Log "Resetting CCM policy (WMI)..."
    Invoke-WMIMethod -Namespace root\ccm -Class SMS_Client -Name ResetPolicy -ArgumentList "1" | Out-Null
    Ui-Log "CCM policy reset requested." "OK"
}

# --------------------------
# Wire up events
# --------------------------
$btnCleanDisk.Add_Click({ Run-Action $ActionCleanDisk "Clean Disk" })
$btnResetWU.Add_Click({ Run-Action $ActionResetWU "Reset Windows Update Components" })
$btnReinstallCCM.Add_Click({ Run-Action $ActionReinstallCCM "Reinstall CCM Agent" })
$btnRebuildWMI.Add_Click({ Run-Action $ActionRebuildWMI "Rebuild WMI Repository" })
$btnResetWMI.Add_Click({ Run-Action $ActionResetWMI "Reset WMI Repository" })
$btnDISM.Add_Click({ Run-Action $ActionDISM "DISM RestoreHealth" })
$btnSFC.Add_Click({ Run-Action $ActionSFC "SFC Scannow" })
$btnDiskSpace.Add_Click({ Run-Action $ActionDiskSpace "Get Disk Free Space" })
$btnClearCache.Add_Click({ Run-Action $ActionClearCache "Clear CCMCache Folder" })
$btnInstalled.Add_Click({ Run-Action $ActionInstalled "Get Installed Software" })
$btnResetPolicy.Add_Click({ Run-Action $ActionResetPolicy "Reset CCM Policies" })

$btnClearLog.Add_Click({
    $txtLog.Clear()
    $txtStatus.Text = "Log cleared."
})

$btnExit.Add_Click({ $Window.Close() })

# Initial message
Ui-Log "Ready."

# Show UI
$Window.ShowDialog() | Out-Null