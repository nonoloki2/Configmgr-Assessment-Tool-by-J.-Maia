Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "PSHInfoView"
$form.Size = New-Object System.Drawing.Size(920,700)
$form.StartPosition = "CenterScreen"

$txtHosts = New-Object System.Windows.Forms.TextBox
$txtHosts.Multiline = $true
$txtHosts.ScrollBars = "Vertical"
$txtHosts.Location = New-Object System.Drawing.Point(10,10)
$txtHosts.Size = New-Object System.Drawing.Size(300,540)
$txtHosts.Font = New-Object System.Drawing.Font("Consolas",10)
$form.Controls.Add($txtHosts)

$btnPing = New-Object System.Windows.Forms.Button
$btnPing.Text = "Test Ping"
$btnPing.Location = New-Object System.Drawing.Point(10,560)
$btnPing.Size = New-Object System.Drawing.Size(140,35)
$form.Controls.Add($btnPing)

$btnCopyOnline = New-Object System.Windows.Forms.Button
$btnCopyOnline.Text = "Copy Online"
$btnCopyOnline.Location = New-Object System.Drawing.Point(170,560)
$btnCopyOnline.Size = New-Object System.Drawing.Size(140,35)
$btnCopyOnline.Enabled = $false
$form.Controls.Add($btnCopyOnline)

$btnSaveOnline = New-Object System.Windows.Forms.Button
$btnSaveOnline.Text = "Save Online hosts.txt"
$btnSaveOnline.Location = New-Object System.Drawing.Point(10,605)
$btnSaveOnline.Size = New-Object System.Drawing.Size(300,35)
$btnSaveOnline.Enabled = $false
$form.Controls.Add($btnSaveOnline)

$list = New-Object System.Windows.Forms.ListView
$list.Location = New-Object System.Drawing.Point(330,10)
$list.Size = New-Object System.Drawing.Size(560,585)
$list.View = "Details"
$list.FullRowSelect = $true
$list.GridLines = $true

[void]$list.Columns.Add("Hostname",220)
[void]$list.Columns.Add("Status",100)
[void]$list.Columns.Add("IP / Resultado",220)

$form.Controls.Add($list)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(330,610)
$status.Size = New-Object System.Drawing.Size(560,30)
$status.Text = "Ready"
$form.Controls.Add($status)

$script:OnlineHosts = @()
$script:Results = @()

function Refresh-List {
    $list.BeginUpdate()
    $list.Items.Clear()

    $ordered = @($script:Results) | Sort-Object @{
        Expression = {
            switch ($_.Status) {
                "Online"  { 0 }
                "Testing" { 1 }
                "Offline" { 2 }
                default   { 3 }
            }
        }
    }, Hostname

    foreach ($r in $ordered) {
        $item = New-Object System.Windows.Forms.ListViewItem($r.Hostname)
        [void]$item.SubItems.Add($r.Status)
        [void]$item.SubItems.Add($r.Result)

        switch ($r.Status) {
            "Online"  { $item.BackColor = [System.Drawing.Color]::LightGreen }
            "Offline" { $item.BackColor = [System.Drawing.Color]::LightCoral }
            "Testing" { $item.BackColor = [System.Drawing.Color]::LightYellow }
        }

        [void]$list.Items.Add($item)
    }

    $list.EndUpdate()

    $script:OnlineHosts = @(
        $script:Results |
        Where-Object { $_.Status -eq "Online" } |
        Sort-Object Hostname |
        Select-Object -ExpandProperty Hostname
    )
}

$btnPing.Add_Click({

    $btnPing.Enabled = $false
    $btnCopyOnline.Enabled = $false
    $btnSaveOnline.Enabled = $false

    $hosts = @(
        $txtHosts.Lines |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" } |
        Select-Object -Unique
    )

    if ($hosts.Count -eq 0) {
        $status.Text = "No hosts informed."
        $btnPing.Enabled = $true
        return
    }

    if ($hosts.Count -gt 100) {
        [System.Windows.Forms.MessageBox]::Show("Limite máximo: 100 dispositivos.","PSHInfoView")
        $btnPing.Enabled = $true
        return
    }

    $script:Results = @(
        foreach ($h in $hosts) {
            [PSCustomObject]@{
                Hostname = $h
                Status   = "Testing"
                Result   = "Waiting..."
            }
        }
    )

    Refresh-List
    $status.Text = "Testing $($hosts.Count) devices..."

    foreach ($hostName in $hosts) {
        $current = $script:Results | Where-Object { $_.Hostname -eq $hostName }

        $current.Result = "Pinging..."
        Refresh-List
        [System.Windows.Forms.Application]::DoEvents()

        try {
            $pingResult = Test-Connection -ComputerName $hostName -Count 2 -Quiet -ErrorAction SilentlyContinue

            if ($pingResult) {
                $ip = "Online"

                try {
                    $resolvedIp = [System.Net.Dns]::GetHostAddresses($hostName) |
                        Where-Object { $_.AddressFamily -eq "InterNetwork" } |
                        Select-Object -First 1

                    if ($resolvedIp) {
                        $ip = $resolvedIp.IPAddressToString
                    }
                } catch {}

                $current.Status = "Online"
                $current.Result = $ip
            }
            else {
                $current.Status = "Offline"
                $current.Result = "No reply"
            }
        }
        catch {
            $current.Status = "Offline"
            $current.Result = "Error / Unreachable"
        }

        Refresh-List
        [System.Windows.Forms.Application]::DoEvents()
    }

    $online = @($script:Results | Where-Object { $_.Status -eq "Online" }).Count
    $offline = @($script:Results | Where-Object { $_.Status -eq "Offline" }).Count

    $status.Text = "Finished - Online: $online | Offline: $offline"

    $btnPing.Enabled = $true

    if ($online -gt 0) {
        $btnCopyOnline.Enabled = $true
        $btnSaveOnline.Enabled = $true
    }
})

$btnCopyOnline.Add_Click({
    if ($script:OnlineHosts.Count -gt 0) {
        [System.Windows.Forms.Clipboard]::SetText(($script:OnlineHosts -join [Environment]::NewLine))
        $status.Text = "$($script:OnlineHosts.Count) online hostnames copied."
    }
})

$btnSaveOnline.Add_Click({
    if ($script:OnlineHosts.Count -eq 0) {
        $status.Text = "No online hosts to save."
        return
    }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Save online hosts"
    $dialog.FileName = "hosts.txt"
    $dialog.Filter = "Text file (*.txt)|*.txt|All files (*.*)|*.*"

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:OnlineHosts | Set-Content -Path $dialog.FileName -Encoding ASCII
        $status.Text = "Saved $($script:OnlineHosts.Count) online hosts to: $($dialog.FileName)"
    }
})

[System.Windows.Forms.Application]::Run($form)