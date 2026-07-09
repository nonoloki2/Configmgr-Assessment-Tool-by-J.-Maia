function Show-CATMainWindow {
    [CmdletBinding()]
    param([object]$Session)

    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ConfigMgr Assessment Tool by J. Maia" Height="780" Width="1280" MinHeight="720" MinWidth="1160"
        WindowStartupLocation="CenterScreen" Background="#F3F3F3" FontFamily="Segoe UI" FontSize="12"
        ResizeMode="CanResizeWithGrip" ShowInTaskbar="True">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#FFFFFF" BorderBrush="#D0D0D0" BorderThickness="1" CornerRadius="4" Padding="16" Margin="0,0,0,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                    <TextBlock Text="ConfigMgr Assessment Tool by J. Maia" FontSize="24" FontWeight="SemiBold" Foreground="#222"/>
                    <TextBlock Name="txtVersion" Text="Version 2.0.7-alpha | Build 0020 | Window Chrome Hotfix" Margin="0,4,0,0" Foreground="#555"/>
                    <TextBlock Name="txtAssessmentID" Text="Assessment ID:" Margin="0,8,0,0" Foreground="#555"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
                    <TextBlock Text="Status:" FontWeight="SemiBold" Margin="0,0,6,0"/>
                    <TextBlock Name="txtHeaderStatus" Text="Ready" Foreground="#267326" FontWeight="SemiBold"/>
                </StackPanel>
            </Grid>
        </Border>

        <Border Grid.Row="1" Background="#FFFFFF" BorderBrush="#D0D0D0" BorderThickness="1" CornerRadius="4" Padding="14" Margin="0,0,0,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="85"/>
                    <ColumnDefinition Width="120"/>
                    <ColumnDefinition Width="110"/>
                    <ColumnDefinition Width="250"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="120"/>
                    <ColumnDefinition Width="120"/>
                    <ColumnDefinition Width="120"/>
                    <ColumnDefinition Width="130"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Column="0" Text="Site Code" VerticalAlignment="Center" FontWeight="SemiBold" Margin="0,0,8,0"/>
                <TextBox Grid.Column="1" Name="txtSiteCode" Height="28" Padding="7,3,7,3" VerticalContentAlignment="Center" HorizontalContentAlignment="Left" Margin="0,0,16,0"/>
                <TextBlock Grid.Column="2" Text="SMS Provider" VerticalAlignment="Center" FontWeight="SemiBold" Margin="0,0,8,0"/>
                <TextBox Grid.Column="3" Name="txtProvider" Height="28" Padding="7,3,7,3" VerticalContentAlignment="Center" HorizontalContentAlignment="Left" Margin="0,0,16,0"/>
                <TextBlock Grid.Column="4" Name="txtCurrentTask" Text="Current task: Ready" VerticalAlignment="Center" Foreground="#555" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" ToolTip="Current task: Ready"/>
                <Button Grid.Column="5" Name="btnDiscovery" Content="Discovery" Height="30" Margin="8,0,8,0" ToolTip="Run Discovery, Core Health and Management Point assessment in sequence."/>
                <Button Grid.Column="6" Name="btnExport" Content="Export CSV" Height="30" Margin="0,0,8,0" IsEnabled="False"/>
                <Button Grid.Column="7" Name="btnHtml" Content="HTML Report" Height="30" Margin="0,0,8,0" IsEnabled="False"/>
                <Button Grid.Column="8" Name="btnOpenOutput" Content="Open Output" Height="30" Margin="0,0,0,0" IsEnabled="False"/>
                <TextBlock Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="9" Name="txtCompletion" Text="Ready to run assessment." Margin="0,10,0,0" Foreground="#555" FontWeight="SemiBold" TextWrapping="Wrap"/>
            </Grid>
        </Border>

        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="300"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Grid Grid.Column="0">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Border Grid.Row="0" Background="#FFFFFF" BorderBrush="#D0D0D0" BorderThickness="1" CornerRadius="4" Padding="12" Margin="0,0,0,10">
                    <StackPanel>
                        <TextBlock Text="Discovery Summary" FontWeight="SemiBold" FontSize="15" Margin="0,0,0,8"/>
                        <UniformGrid Columns="2" Rows="6">
                            <TextBlock Text="Servers" Foreground="#555"/><TextBlock Name="sumServers" Text="0" FontWeight="SemiBold"/>
                            <TextBlock Text="Role Instances" Foreground="#555"/><TextBlock Name="sumRoles" Text="0" FontWeight="SemiBold"/>
                            <TextBlock Text="Management Points" Foreground="#555"/><TextBlock Name="sumMP" Text="0" FontWeight="SemiBold"/>
                            <TextBlock Text="Distribution Points" Foreground="#555"/><TextBlock Name="sumDP" Text="0" FontWeight="SemiBold"/>
                            <TextBlock Text="Software Update Points" Foreground="#555"/><TextBlock Name="sumSUP" Text="0" FontWeight="SemiBold"/>
                            <TextBlock Text="Reporting Points" Foreground="#555"/><TextBlock Name="sumRP" Text="0" FontWeight="SemiBold"/>
                        </UniformGrid>
                    </StackPanel>
                </Border>

                <Border Grid.Row="1" Background="#FFFFFF" BorderBrush="#D0D0D0" BorderThickness="1" CornerRadius="4" Padding="10" Margin="0,0,0,10">
                    <DockPanel>
                        <TextBlock DockPanel.Dock="Top" Text="Topology" FontWeight="SemiBold" FontSize="15" Margin="0,0,0,8"/>
                        <TreeView Name="treeTopology" BorderThickness="0"/>
                    </DockPanel>
                </Border>

                <Border Grid.Row="2" Background="#FFFFFF" BorderBrush="#D0D0D0" BorderThickness="1" CornerRadius="4" Padding="10">
                    <StackPanel>
                        <TextBlock Text="Progress" FontWeight="SemiBold" FontSize="15" Margin="0,0,0,8"/>
                        <ProgressBar Name="progressBar" Minimum="0" Maximum="100" Value="0" Height="18"/>
                        <TextBlock Name="txtElapsed" Text="Elapsed: 00:00:00" Margin="0,8,0,0" Foreground="#555"/>
                    </StackPanel>
                </Border>
            </Grid>

            <TabControl Grid.Column="2" Name="tabs">
                <TabItem Header="Results">
                    <DataGrid Name="gridResults" AutoGenerateColumns="False" IsReadOnly="True" CanUserSortColumns="True" SelectionMode="Extended" GridLinesVisibility="Horizontal" AlternatingRowBackground="#F7F7F7" RowHeaderWidth="0">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="105"/>
                            <DataGridTextColumn Header="Severity" Binding="{Binding Severity}" Width="90"/>
                            <DataGridTextColumn Header="Module" Binding="{Binding Module}" Width="100"/>
                            <DataGridTextColumn Header="Category" Binding="{Binding Category}" Width="120"/>
                            <DataGridTextColumn Header="Check" Binding="{Binding Check}" Width="160"/>
                            <DataGridTextColumn Header="Target" Binding="{Binding Target}" Width="160"/>
                            <DataGridTextColumn Header="Role" Binding="{Binding Role}" Width="180"/>
                            <DataGridTextColumn Header="Value" Binding="{Binding Value}" Width="220"/>
                            <DataGridTextColumn Header="Finding" Binding="{Binding Finding}" Width="*"/>
                            <DataGridTextColumn Header="Impact" Binding="{Binding Impact}" Width="90"/>
                            <DataGridTextColumn Header="Evidence" Binding="{Binding Evidence}" Width="260"/>
                            <DataGridTextColumn Header="Rule" Binding="{Binding RuleId}" Width="130"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </TabItem>
                <TabItem Header="Execution Log">
                    <TextBox Name="txtLog" IsReadOnly="True" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12" Background="#1E1E1E" Foreground="#EEEEEE" Padding="8" TextWrapping="NoWrap"/>
                </TabItem>
                <TabItem Header="Debug">
                    <TextBox Name="txtDebug" IsReadOnly="True" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12" Padding="8"/>
                </TabItem>
            </TabControl>
        </Grid>

        <StatusBar Grid.Row="3" Margin="0,10,0,0">
            <StatusBarItem><TextBlock Name="statusLeft" Text="Ready"/></StatusBarItem>
            <Separator/>
            <StatusBarItem><TextBlock Name="statusLog" Text="Log: not initialized"/></StatusBarItem>
            <Separator/>
            <StatusBarItem><TextBlock Name="statusCsv" Text="CSV: not exported"/></StatusBarItem>
        </StatusBar>
    </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $names = 'txtVersion','txtAssessmentID','txtHeaderStatus','txtSiteCode','txtProvider','txtCurrentTask','txtCompletion','btnDiscovery','btnExport','btnHtml','btnOpenOutput','sumServers','sumRoles','sumMP','sumDP','sumSUP','sumRP','treeTopology','progressBar','txtElapsed','gridResults','txtLog','txtDebug','statusLeft','statusLog','statusCsv'
    $ui = @{}
    foreach($n in $names){ $ui[$n] = $window.FindName($n) }

    $ui.txtAssessmentID.Text = "Assessment ID: $($Session.AssessmentID)"
    $ui.statusLog.Text = "Log: $($Session.LogFile)"
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $script:CATDiscoveryStopwatch = [System.Diagnostics.Stopwatch]::new()
    $timer.Add_Tick({
        if ($script:CATDiscoveryStopwatch -and $script:CATDiscoveryStopwatch.IsRunning) {
            $ui.txtElapsed.Text = 'Elapsed: ' + $script:CATDiscoveryStopwatch.Elapsed.ToString('hh\:mm\:ss')
        }
    })

    function Add-UiLog([string]$Message,[string]$Level='INFO') {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
        $ui.txtLog.AppendText($line + [Environment]::NewLine)
        $ui.txtLog.ScrollToEnd()
        $ui.statusLeft.Text = $Message
    }

    function Set-CurrentTaskText([string]$Message) {
        $text = "Current task: $Message"
        $ui.txtCurrentTask.Text = $text
        $ui.txtCurrentTask.ToolTip = $text
        $ui.statusLeft.Text = $Message
    }

    function Get-CATOutputFolderForUi {
        if ($Session.LastHtmlPath -and (Test-Path -LiteralPath $Session.LastHtmlPath)) {
            return (Split-Path -Parent $Session.LastHtmlPath)
        }
        if ($Session.LastCsvPath -and (Test-Path -LiteralPath $Session.LastCsvPath)) {
            return (Split-Path -Parent $Session.LastCsvPath)
        }
        $defaultOutput = Join-Path $Session.AppRoot 'Output'
        if (-not (Test-Path -LiteralPath $defaultOutput)) {
            New-Item -ItemType Directory -Path $defaultOutput -Force | Out-Null
        }
        return $defaultOutput
    }

    function Reset-CATUiRunState {
        $Session.StartTime = Get-Date
        $Session.Results.Clear()
        $Session.Inventory.Site = $null
        $Session.Inventory.Servers = @()
        $Session.Inventory.Roles = @()
        $Session.Inventory.Counts = [ordered]@{}
        $Session.Inventory.SQL = $null
        $Session.Inventory.Boundaries = @()
        $Session.Inventory.BoundaryGroups = @()
        $Session.Inventory.CoreHealth = $null
        $Session.Inventory.HealthScore = $null
        $Session.LastCsvPath = $null
        $Session.LastHtmlPath = $null
        $ui.gridResults.ItemsSource = $null
        $ui.treeTopology.Items.Clear()
        $ui.sumServers.Text = '0'
        $ui.sumRoles.Text = '0'
        $ui.sumMP.Text = '0'
        $ui.sumDP.Text = '0'
        $ui.sumSUP.Text = '0'
        $ui.sumRP.Text = '0'
        $ui.statusCsv.Text = 'CSV: not exported'
        $ui.txtCompletion.Text = 'Assessment is running. Please wait...'
        $ui.txtCompletion.Foreground = '#555'
        $ui.txtDebug.Text = ''
    }

    function Refresh-Results {
        $ui.gridResults.ItemsSource = $null
        $ui.gridResults.ItemsSource = @($Session.Results)
        $ui.btnExport.IsEnabled = ($Session.Results.Count -gt 0)
        $ui.btnHtml.IsEnabled = ($Session.Results.Count -gt 0)
    }

    function Update-Summary {
        $counts = $Session.Inventory.Counts
        $ui.sumServers.Text = [string]$(if($counts.Servers){$counts.Servers}else{0})
        $ui.sumRoles.Text = [string]$(if($counts.RoleInstances){$counts.RoleInstances}else{0})
        $ui.sumMP.Text = [string]@($Session.Inventory.Roles | Where-Object RoleName -like '*Management Point*').Count
        $ui.sumDP.Text = [string]@($Session.Inventory.Roles | Where-Object RoleName -like '*Distribution Point*').Count
        $ui.sumSUP.Text = [string]@($Session.Inventory.Roles | Where-Object RoleName -like '*Software Update Point*').Count
        $ui.sumRP.Text = [string]@($Session.Inventory.Roles | Where-Object RoleName -like '*Reporting*').Count
    }

    function Update-Topology {
        $ui.treeTopology.Items.Clear()
        $siteName = if($Session.Inventory.Site -and $Session.Inventory.Site.SiteCode){$Session.Inventory.Site.SiteCode}else{'ConfigMgr Site'}
        $root = New-Object System.Windows.Controls.TreeViewItem
        $root.Header = $siteName
        $root.IsExpanded = $true
        foreach($srv in $Session.Inventory.Servers){
            $srvItem = New-Object System.Windows.Controls.TreeViewItem
            $srvItem.Header = $srv
            $srvItem.IsExpanded = $false
            $srvRoles = @($Session.Inventory.Roles | Where-Object ServerName -eq $srv | Select-Object -ExpandProperty RoleName)
            foreach($role in $srvRoles){
                $roleItem = New-Object System.Windows.Controls.TreeViewItem
                $roleItem.Header = $role
                [void]$srvItem.Items.Add($roleItem)
            }
            [void]$root.Items.Add($srvItem)
        }
        [void]$ui.treeTopology.Items.Add($root)
    }

    function Set-CATButtonsRunning([bool]$IsRunning) {
        $ui.btnDiscovery.IsEnabled = (-not $IsRunning)
        $ui.btnExport.IsEnabled = ((-not $IsRunning) -and $Session.Results.Count -gt 0)
        $ui.btnHtml.IsEnabled = ((-not $IsRunning) -and $Session.Results.Count -gt 0)
        $ui.btnOpenOutput.IsEnabled = ((-not $IsRunning) -and (($Session.LastCsvPath -and (Test-Path -LiteralPath $Session.LastCsvPath)) -or ($Session.LastHtmlPath -and (Test-Path -LiteralPath $Session.LastHtmlPath))))
    }

    $ui.btnDiscovery.Add_Click({
        try {
            Reset-CATUiRunState
            $ui.btnDiscovery.Content = 'Running...'
            Set-CATButtonsRunning $true
            $ui.txtElapsed.Text = 'Elapsed: 00:00:00'
            $timer.Stop()
            $script:CATDiscoveryStopwatch.Reset()
            $script:CATDiscoveryStopwatch.Start()
            $timer.Start()
            $ui.txtHeaderStatus.Text = 'Running'
            $ui.txtHeaderStatus.Foreground = 'DarkOrange'
            $ui.progressBar.Value = 0
            Add-UiLog 'Assessment workflow started.'
            $progressCb = { param($p,$task) $ui.progressBar.Value = $p; Set-CurrentTaskText $task }
            $logCb = { param($msg,$level) Add-UiLog $msg $level }

            Add-UiLog 'Step 1/3 - Discovery started.'
            Invoke-CATDiscovery -Session $Session -SiteCode $ui.txtSiteCode.Text -ProviderServer $ui.txtProvider.Text -ProgressCallback $progressCb -LogCallback $logCb | Out-Null
            Update-Summary
            Update-Topology
            Refresh-Results

            Add-UiLog 'Step 2/3 - Core Health started.'
            $ui.progressBar.Value = 0
            $coreSummary = Invoke-CATCoreHealth -Session $Session -ProgressCallback $progressCb -LogCallback $logCb
            Refresh-Results

            $mpSummary = $null
            $mpCount = @($Session.Inventory.Roles | Where-Object RoleName -like '*Management Point*').Count
            if ($mpCount -gt 0) {
                Add-UiLog 'Step 3/3 - Management Point assessment started.'
                $ui.progressBar.Value = 0
                $mpSummary = Invoke-CATManagementPointAssessment -Session $Session -ProgressCallback $progressCb -LogCallback $logCb
                Refresh-Results
            } else {
                Add-UiLog 'Step 3/3 - Management Point assessment skipped. No MP role found.' 'INFO'
            }

            $csv = Export-CATCsv -Session $Session
            $Session.LastCsvPath = $csv
            $ui.statusCsv.Text = "CSV: $csv"
            Add-UiLog "CSV exported: $csv"
            $script:CATDiscoveryStopwatch.Stop()
            $timer.Stop()
            $elapsedText = $script:CATDiscoveryStopwatch.Elapsed.ToString('hh\:mm\:ss')
            $ui.txtElapsed.Text = 'Elapsed: ' + $elapsedText
            $serverCount = @($Session.Inventory.Servers).Count
            $roleCount = @($Session.Inventory.Roles).Count
            $mpText = if ($mpSummary) { ' | MPs: {0} | MP Warning: {1} | MP Critical: {2}' -f $mpSummary.ManagementPoints,$mpSummary.Warning,$mpSummary.Critical } else { ' | MPs: 0' }
            $summary = 'Assessment completed | Servers: {0} | Roles: {1}{2} | CSV exported | Elapsed: {3}' -f $serverCount,$roleCount,$mpText,$elapsedText
            $ui.txtHeaderStatus.Text = 'Completed'
            $ui.txtHeaderStatus.Foreground = 'Green'
            Set-CurrentTaskText 'Assessment completed - Ready for next action'
            $ui.txtCompletion.Text = $summary
            $ui.txtCompletion.Foreground = 'Green'
            $ui.progressBar.Value = 100
            $ui.btnOpenOutput.IsEnabled = $true
            $ui.btnHtml.IsEnabled = $true
            $ui.txtDebug.Text = "AssessmentID: $($Session.AssessmentID)`r`nLogFile: $($Session.LogFile)`r`nCSV: $csv`r`nServers: $serverCount`r`nRoles: $roleCount`r`nCoreHealth Servers: $($coreSummary.Servers)`r`nElapsed: $elapsedText"
            [System.Windows.MessageBox]::Show($summary + "`n`nCSV:`n$csv", 'Assessment completed', 'OK', 'Information') | Out-Null
        } catch {
            if ($script:CATDiscoveryStopwatch -and $script:CATDiscoveryStopwatch.IsRunning) { $script:CATDiscoveryStopwatch.Stop() }
            $timer.Stop()
            Add-UiLog $_.Exception.Message 'ERROR'
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Assessment failed', 'OK', 'Error') | Out-Null
            Refresh-Results
            $ui.txtHeaderStatus.Text = 'Failed'
            $ui.txtHeaderStatus.Foreground = 'Red'
            $ui.txtCurrentTask.Text = 'Current task: Failed'
            $ui.txtCompletion.Text = 'Assessment failed. Review the Execution Log tab.'
            $ui.txtCompletion.Foreground = 'Red'
        } finally {
            $ui.btnDiscovery.Content = 'Discovery'
            Set-CATButtonsRunning $false
        }
    })

    $ui.btnExport.Add_Click({
        try {
            $csv = Export-CATCsv -Session $Session
            $Session.LastCsvPath = $csv
            $ui.statusCsv.Text = "CSV: $csv"
            $ui.btnOpenOutput.IsEnabled = $true
            $ui.btnHtml.IsEnabled = $true
            Add-UiLog "CSV exported: $csv"
            [System.Windows.MessageBox]::Show("CSV exported:`n$csv", 'Export CSV', 'OK', 'Information') | Out-Null
        } catch { [System.Windows.MessageBox]::Show($_.Exception.Message, 'Export failed', 'OK', 'Error') | Out-Null }
    })

    $ui.btnHtml.Add_Click({
        try {
            if (-not $Session.Results -or $Session.Results.Count -eq 0) {
                [System.Windows.MessageBox]::Show('Run Discovery before generating the HTML report.', 'HTML Report', 'OK', 'Warning') | Out-Null
                return
            }
            Add-UiLog 'Generating HTML report.'
            $html = Export-CATHtmlReport -Session $Session
            $Session.LastHtmlPath = $html
            $ui.btnOpenOutput.IsEnabled = $true
            Add-UiLog "HTML report generated: $html"
            [System.Windows.MessageBox]::Show("HTML report generated:`n$html", 'HTML Report', 'OK', 'Information') | Out-Null
            Start-Process -FilePath $html
        } catch {
            Add-UiLog $_.Exception.Message 'ERROR'
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'HTML Report failed', 'OK', 'Error') | Out-Null
        }
    })

    $ui.btnOpenOutput.Add_Click({
        try {
            $folder = Get-CATOutputFolderForUi
            if (-not (Test-Path -LiteralPath $folder)) {
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
            }
            Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $folder)
            Add-UiLog "Opened output folder: $folder"
        } catch {
            Add-UiLog $_.Exception.Message 'ERROR'
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Open Output failed', 'OK', 'Error') | Out-Null
        }
    })

    Add-UiLog 'Application ready.'
    [void]$window.ShowDialog()
}
Export-ModuleMember -Function *
