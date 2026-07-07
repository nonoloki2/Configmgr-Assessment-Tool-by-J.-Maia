# ConfigMgr Assessment Tool by J. Maia
# Version: 1.0.0-alpha - Phase 1
# Purpose: GUI base, Discovery, logging and CSV export.

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$Script:BasePath = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:ModulesPath = Join-Path $Script:BasePath 'Modules'
$Script:OutputCsvPath = Join-Path $Script:BasePath 'Output\CSV'
$Script:OutputLogPath = Join-Path $Script:BasePath 'Output\Logs'
$Script:AssessmentId = [guid]::NewGuid().ToString()
$Script:Results = New-Object System.Collections.Generic.List[object]
$Script:LastCsv = $null
$Script:LastLog = $null

Import-Module (Join-Path $Script:ModulesPath 'Common.psm1') -Force
Import-Module (Join-Path $Script:ModulesPath 'Logging.psm1') -Force
Import-Module (Join-Path $Script:ModulesPath 'Export.psm1') -Force
Import-Module (Join-Path $Script:ModulesPath 'Discovery.psm1') -Force

Ensure-Directory -Path $Script:OutputCsvPath
Ensure-Directory -Path $Script:OutputLogPath

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ConfigMgr Assessment Tool by J. Maia" Height="720" Width="980"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResize">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Padding="14" BorderBrush="#BDBDBD" BorderThickness="1" CornerRadius="8">
            <StackPanel>
                <TextBlock Text="ConfigMgr Assessment Tool by J. Maia" FontSize="26" FontWeight="Bold"/>
                <TextBlock Text="Version 1.0.0-alpha | Phase 1 - Base, Discovery, Logging and CSV Export" FontSize="13" Margin="0,4,0,0"/>
                <TextBlock Name="TxtAssessmentId" FontSize="12" Margin="0,8,0,0"/>
            </StackPanel>
        </Border>

        <Border Grid.Row="1" Padding="14" Margin="0,12,0,0" BorderBrush="#BDBDBD" BorderThickness="1" CornerRadius="8">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="120"/>
                    <ColumnDefinition Width="220"/>
                    <ColumnDefinition Width="130"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <TextBlock Grid.Row="0" Grid.Column="0" Text="Site Code:" VerticalAlignment="Center" FontWeight="SemiBold"/>
                <TextBox Grid.Row="0" Grid.Column="1" Name="TxtSiteCode" Height="28" Margin="0,0,18,0" ToolTip="Example: PR1"/>
                <TextBlock Grid.Row="0" Grid.Column="2" Text="SMS Provider:" VerticalAlignment="Center" FontWeight="SemiBold"/>
                <TextBox Grid.Row="0" Grid.Column="3" Name="TxtProvider" Height="28" ToolTip="Server hosting SMS Provider. Often the Primary Site Server."/>

                <TextBlock Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="4" Margin="0,10,0,0" Text="Tip: use the SMS Provider server. In many environments this is the Primary Site Server, but it can be installed on a different server." TextWrapping="Wrap"/>
            </Grid>
        </Border>

        <Border Grid.Row="2" Padding="14" Margin="0,12,0,0" BorderBrush="#BDBDBD" BorderThickness="1" CornerRadius="8">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button Name="BtnDiscovery" Grid.Column="0" Content="Run Discovery" Width="140" Height="34" Margin="0,0,10,0"/>
                <Button Name="BtnExport" Grid.Column="1" Content="Export CSV" Width="120" Height="34" Margin="0,0,10,0" IsEnabled="False"/>
                <Button Name="BtnClear" Grid.Column="2" Content="Clear Log" Width="100" Height="34" Margin="0,0,10,0"/>
                <Button Name="BtnExit" Grid.Column="3" Content="Exit" Width="90" Height="34"/>
            </Grid>
        </Border>

        <Grid Grid.Row="3" Margin="0,12,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="300"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Padding="14" BorderBrush="#BDBDBD" BorderThickness="1" CornerRadius="8">
                <StackPanel>
                    <TextBlock Text="Modules" FontSize="17" FontWeight="Bold" Margin="0,0,0,8"/>
                    <CheckBox Name="ChkDiscovery" Content="Discovery" IsChecked="True" IsEnabled="False" Margin="0,4,0,4"/>
                    <CheckBox Name="ChkCore" Content="Core Health - Coming soon" IsEnabled="False" Margin="0,4,0,4"/>
                    <CheckBox Name="ChkComponent" Content="Component Status - Coming soon" IsEnabled="False" Margin="0,4,0,4"/>
                    <CheckBox Name="ChkRoles" Content="Role Assessment - Coming soon" IsEnabled="False" Margin="0,4,0,4"/>
                    <CheckBox Name="ChkWSUS" Content="SUP / WSUS - Coming soon" IsEnabled="False" Margin="0,4,0,4"/>
                    <CheckBox Name="ChkDistribution" Content="Distribution Content Status - Coming soon" IsEnabled="False" Margin="0,4,0,4"/>
                    <CheckBox Name="ChkSQL" Content="SQL Assessment - Separate phase" IsEnabled="False" Margin="0,4,0,4"/>
                    <Separator Margin="0,12,0,12"/>
                    <TextBlock Text="Current Phase" FontWeight="Bold"/>
                    <TextBlock Text="Phase 1: validates inputs, ping, WinRM, SMS Provider namespace, site metadata and site system roles." TextWrapping="Wrap" Margin="0,4,0,0"/>
                </StackPanel>
            </Border>

            <Border Grid.Column="2" Padding="14" BorderBrush="#BDBDBD" BorderThickness="1" CornerRadius="8">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="180"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="Execution Log" FontSize="17" FontWeight="Bold"/>
                        <TextBlock Name="TxtElapsed" Grid.Column="1" Text="Elapsed: 00:00:00" HorizontalAlignment="Right"/>
                    </Grid>
                    <ProgressBar Name="ProgressBar" Grid.Row="1" Height="20" Minimum="0" Maximum="100" Value="0" Margin="0,10,0,10"/>
                    <TextBox Name="TxtLog" Grid.Row="2" FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" IsReadOnly="True" AcceptsReturn="True"/>
                </Grid>
            </Border>
        </Grid>

        <StatusBar Grid.Row="4" Margin="0,12,0,0">
            <StatusBarItem>
                <TextBlock Name="TxtStatus" Text="Ready."/>
            </StatusBarItem>
        </StatusBar>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$TxtAssessmentId = $window.FindName('TxtAssessmentId')
$TxtSiteCode     = $window.FindName('TxtSiteCode')
$TxtProvider     = $window.FindName('TxtProvider')
$BtnDiscovery    = $window.FindName('BtnDiscovery')
$BtnExport       = $window.FindName('BtnExport')
$BtnClear        = $window.FindName('BtnClear')
$BtnExit         = $window.FindName('BtnExit')
$TxtLog          = $window.FindName('TxtLog')
$TxtStatus       = $window.FindName('TxtStatus')
$TxtElapsed      = $window.FindName('TxtElapsed')
$ProgressBar     = $window.FindName('ProgressBar')

$TxtAssessmentId.Text = "Assessment ID: $Script:AssessmentId"

function Add-UILog {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )
    $line = Write-CATLog -Message $Message -Level $Level
    $TxtLog.AppendText($line + [Environment]::NewLine)
    $TxtLog.ScrollToEnd()
    $TxtStatus.Text = $Message
    [System.Windows.Forms.Application]::DoEvents() | Out-Null
}

try { Add-Type -AssemblyName System.Windows.Forms } catch {}

$BtnClear.Add_Click({
    $TxtLog.Clear()
})

$BtnExit.Add_Click({
    $window.Close()
})

$BtnExport.Add_Click({
    if ($Script:Results.Count -eq 0) {
        [System.Windows.MessageBox]::Show('No results to export yet.', 'ConfigMgr Assessment Tool by J. Maia', 'OK', 'Information') | Out-Null
        return
    }
    try {
        $siteCode = $TxtSiteCode.Text.Trim().ToUpper()
        $Script:LastCsv = Export-CATCsv -Results $Script:Results.ToArray() -OutputDirectory $Script:OutputCsvPath -AssessmentId $Script:AssessmentId -SiteCode $siteCode
        Add-UILog "CSV exported: $Script:LastCsv" 'SUCCESS'
        [System.Windows.MessageBox]::Show("CSV exported successfully:`n$Script:LastCsv", 'Export CSV', 'OK', 'Information') | Out-Null
    } catch {
        Add-UILog "CSV export failed: $($_.Exception.Message)" 'ERROR'
        [System.Windows.MessageBox]::Show("CSV export failed:`n$($_.Exception.Message)", 'Export CSV', 'OK', 'Error') | Out-Null
    }
})

$BtnDiscovery.Add_Click({
    $BtnDiscovery.IsEnabled = $false
    $BtnExport.IsEnabled = $false
    $ProgressBar.Value = 0
    $Script:AssessmentId = [guid]::NewGuid().ToString()
    $TxtAssessmentId.Text = "Assessment ID: $Script:AssessmentId"
    $Script:Results.Clear()

    $start = Get-Date
    $Script:LastLog = Initialize-CATLog -LogDirectory $Script:OutputLogPath -AssessmentId $Script:AssessmentId

    try {
        Add-UILog 'Starting Discovery module...' 'INFO'
        $ProgressBar.Value = 10

        $siteCode = $TxtSiteCode.Text.Trim().ToUpper()
        $provider = $TxtProvider.Text.Trim()

        $logger = {
            param($Message, $Level)
            Add-UILog -Message $Message -Level $Level
            $elapsed = (Get-Date) - $start
            $TxtElapsed.Text = ('Elapsed: {0:hh\:mm\:ss}' -f $elapsed)
        }

        $ProgressBar.Value = 25
        $discoveryResults = Invoke-CATDiscovery -SiteCode $siteCode -ProviderServer $provider -AssessmentId $Script:AssessmentId -Logger $logger
        foreach ($item in $discoveryResults) { [void]$Script:Results.Add($item) }

        $ProgressBar.Value = 100
        $elapsed = (Get-Date) - $start
        $TxtElapsed.Text = ('Elapsed: {0:hh\:mm\:ss}' -f $elapsed)
        Add-UILog "Discovery finished. Results collected: $($Script:Results.Count). Log: $Script:LastLog" 'SUCCESS'
        $BtnExport.IsEnabled = $true
    } catch {
        Add-UILog "Unexpected error: $($_.Exception.Message)" 'ERROR'
        [System.Windows.MessageBox]::Show("Unexpected error:`n$($_.Exception.Message)", 'Discovery Error', 'OK', 'Error') | Out-Null
    } finally {
        $BtnDiscovery.IsEnabled = $true
    }
})

$null = $window.ShowDialog()
