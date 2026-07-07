function Show-CATMainWindow {
    [CmdletBinding()]
    param([object]$Session)

    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ConfigMgr Assessment Tool by J. Maia" Height="760" Width="1180" MinHeight="700" MinWidth="1050" WindowStartupLocation="CenterScreen" Background="#F3F3F3" FontFamily="Segoe UI" FontSize="12">
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
                    <TextBlock Name="txtVersion" Text="Version 1.1.1-alpha | Build 0006 | Completion UX Fixes" Margin="0,4,0,0" Foreground="#555"/>
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
                    <ColumnDefinition Width="255"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="125"/>
                    <ColumnDefinition Width="105"/>
                    <ColumnDefinition Width="130"/>
                    <ColumnDefinition Width="70"/>
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
                <Button Grid.Column="5" Name="btnDiscovery" Content="Run Discovery" Height="30" Margin="8,0,8,0"/>
                <Button Grid.Column="6" Name="btnExport" Content="Export CSV" Height="30" Margin="0,0,8,0" IsEnabled="False"/>
                <Button Grid.Column="7" Name="btnOpenOutput" Content="Open Output" Height="30" Margin="0,0,8,0" IsEnabled="False"/>
                <Button Grid.Column="8" Name="btnExit" Content="Exit" Height="30"/>
                <TextBlock Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="9" Name="txtCompletion" Text="Ready to run discovery." Margin="0,10,0,0" Foreground="#555" FontWeight="SemiBold" TextWrapping="Wrap"/>
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
                            <DataGridTextColumn Header="Finding" Binding="{Binding Finding}" Width="*"/>
                            <DataGridTextColumn Header="Evidence" Binding="{Binding Evidence}" Width="220"/>
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

    $names = 'txtVersion','txtAssessmentID','txtHeaderStatus','txtSiteCode','txtProvider','txtCurrentTask','txtCompletion','btnDiscovery','btnExport','btnOpenOutput','btnExit','sumServers','sumRoles','sumMP','sumDP','sumSUP','sumRP','treeTopology','progressBar','txtElapsed','gridResults','txtLog','txtDebug','statusLeft','statusLog','statusCsv'
    $ui = @{}
    foreach($n in $names){ $ui[$n] = $window.FindName($n) }

    $ui.txtAssessmentID.Text = "Assessment ID: $($Session.AssessmentID)"
    $ui.statusLog.Text = "Log: $($Session.LogFile)"
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({
        $elapsed = (Get-Date) - $Session.StartTime
        $ui.txtElapsed.Text = 'Elapsed: {0:hh\:mm\:ss}' -f $elapsed
    })
    $timer.Start()

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


    function Refresh-Results {
        $ui.gridResults.ItemsSource = $null
        $ui.gridResults.ItemsSource = @($Session.Results)
        $ui.btnExport.IsEnabled = ($Session.Results.Count -gt 0)
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

    $ui.btnDiscovery.Add_Click({
        try {
            $ui.btnDiscovery.IsEnabled = $false
            $ui.btnExport.IsEnabled = $false
            $ui.btnOpenOutput.IsEnabled = $false
            $ui.txtCompletion.Text = 'Discovery is running. Please wait...'
            $ui.txtCompletion.Foreground = '#555'
            $ui.txtHeaderStatus.Text = 'Running'
            $ui.txtHeaderStatus.Foreground = 'DarkOrange'
            $ui.progressBar.Value = 0
            Add-UiLog 'Discovery started.'
            $progressCb = { param($p,$task) $ui.progressBar.Value = $p; Set-CurrentTaskText $task }
            $logCb = { param($msg,$level) Add-UiLog $msg $level }
            Invoke-CATDiscovery -Session $Session -SiteCode $ui.txtSiteCode.Text -ProviderServer $ui.txtProvider.Text -ProgressCallback $progressCb -LogCallback $logCb | Out-Null
            Refresh-Results
            Update-Summary
            Update-Topology
            $csv = Export-CATCsv -Session $Session
            $ui.statusCsv.Text = "CSV: $csv"
            Add-UiLog "CSV exported: $csv"
            $serverCount = @($Session.Inventory.Servers).Count
            $roleCount = @($Session.Inventory.Roles).Count
            $elapsed = (Get-Date) - $Session.StartTime
            $summary = 'Discovery completed successfully | Servers: {0} | Roles: {1} | CSV exported | Elapsed: {2:hh\:mm\:ss}' -f $serverCount, $roleCount, $elapsed
            $ui.txtHeaderStatus.Text = 'Completed'
            $ui.txtHeaderStatus.Foreground = 'Green'
            Set-CurrentTaskText 'Discovery completed successfully - Ready for next action'
            $ui.txtCompletion.Text = $summary
            $ui.txtCompletion.Foreground = 'Green'
            $ui.progressBar.Value = 100
            $ui.btnOpenOutput.IsEnabled = $true
            $ui.txtDebug.Text = "AssessmentID: $($Session.AssessmentID)`r`nLogFile: $($Session.LogFile)`r`nCSV: $csv`r`nServers: $serverCount`r`nRoles: $roleCount`r`nElapsed: $($elapsed.ToString('hh\:mm\:ss'))"
            [System.Windows.MessageBox]::Show($summary + "`n`nCSV:`n$csv", 'Discovery completed', 'OK', 'Information') | Out-Null
        } catch {
            Add-UiLog $_.Exception.Message 'ERROR'
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Discovery failed', 'OK', 'Error') | Out-Null
            Refresh-Results
            $ui.txtHeaderStatus.Text = 'Failed'
            $ui.txtHeaderStatus.Foreground = 'Red'
            $ui.txtCurrentTask.Text = 'Current task: Failed'
        } finally {
            $ui.btnDiscovery.IsEnabled = $true
        }
    })

    $ui.btnExport.Add_Click({
        try {
            $csv = Export-CATCsv -Session $Session
            $ui.statusCsv.Text = "CSV: $csv"
            $ui.btnOpenOutput.IsEnabled = $true
            Add-UiLog "CSV exported: $csv"
            [System.Windows.MessageBox]::Show("CSV exported:`n$csv", 'Export CSV', 'OK', 'Information') | Out-Null
        } catch { [System.Windows.MessageBox]::Show($_.Exception.Message, 'Export failed', 'OK', 'Error') | Out-Null }
    })

    $ui.btnExit.Add_Click({ $window.Close() })
    Add-UiLog 'Application ready.'
    [void]$window.ShowDialog()
}
Export-ModuleMember -Function *
