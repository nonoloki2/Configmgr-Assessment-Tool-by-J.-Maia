<#
.SYNOPSIS
Automatically installs Windows Updates with a graphical interface.

.DESCRIPTION
Uses PSWindowsUpdate module to search and install Windows/Microsoft Updates.
Shows a Windows Forms interface with a progress bar and live log.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- UI ----------
$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = "Windows Update Installer"
$script:form.Size = New-Object System.Drawing.Size(640,420)
$script:form.StartPosition = "CenterScreen"

$script:progressBar = New-Object System.Windows.Forms.ProgressBar
$script:progressBar.Location = New-Object System.Drawing.Point(20,20)
$script:progressBar.Size = New-Object System.Drawing.Size(580,28)
$script:progressBar.Style = 'Continuous'
$script:form.Controls.Add($script:progressBar)

$script:textBox = New-Object System.Windows.Forms.TextBox
$script:textBox.Multiline = $true
$script:textBox.ScrollBars = "Vertical"
$script:textBox.ReadOnly = $true
$script:textBox.Location = New-Object System.Drawing.Point(20,60)
$script:textBox.Size = New-Object System.Drawing.Size(580,290)
$script:form.Controls.Add($script:textBox)

$script:closeBtn = New-Object System.Windows.Forms.Button
$script:closeBtn.Text = "Close"
$script:closeBtn.Location = New-Object System.Drawing.Point(520,360)
$script:closeBtn.Size = New-Object System.Drawing.Size(80,28)
$script:closeBtn.Enabled = $false
$script:closeBtn.Visible = $false
$script:closeBtn.Add_Click({ $script:form.Close() })
$script:form.Controls.Add($script:closeBtn)

# ---------- UI Update Helper ----------
function Update-UI {
    param([string]$Message,[int]$Step,[int]$Total)

    $action = [System.Action]{
        $script:textBox.AppendText($Message + [Environment]::NewLine)
        if ($Total -gt 0) {
            $pct = [math]::Min(100, [math]::Max(0, [math]::Round(($Step/$Total)*100)))
            $script:progressBar.Value = $pct
        }
    }

    $script:form.BeginInvoke($action) | Out-Null
}

# ---------- Background Worker ----------
$worker = New-Object System.ComponentModel.BackgroundWorker
$worker.WorkerReportsProgress = $false
$worker.WorkerSupportsCancellation = $false

$worker.add_DoWork({

    # Check if running as admin
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Update-UI "This script must be run as Administrator." 0 1
        return
    }

    Update-UI "Connecting to Windows Update service..." 0 1

    # Import PSWindowsUpdate
    try {
        Import-Module PSWindowsUpdate -Force -ErrorAction Stop
        Update-UI "PSWindowsUpdate module loaded successfully." 0 1
    } catch {
        Update-UI ("PSWindowsUpdate module not found: " + $_.Exception.Message) 0 1
        Update-UI "Install it with: Install-Module PSWindowsUpdate -Scope AllUsers" 0 1
        return
    }

    # Enable Microsoft Update service if available
    try { 
        Add-WUServiceManager -MicrosoftUpdate -ErrorAction SilentlyContinue | Out-Null 
        Update-UI "Microsoft Update service enabled." 0 1
    } catch {
        Update-UI "Warning: Could not enable Microsoft Update service." 0 1
    }

    # Search for updates
    Update-UI "Searching for available updates..." 0 1
    $updates = Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
    $total = ($updates | Measure-Object).Count

    if ($total -eq 0) {
        Update-UI "No updates found." 1 1
        $msgAction = [System.Action]{ 
            [System.Windows.Forms.MessageBox]::Show("No updates were found on this system.","Windows Update Installer") 
        }
        $script:form.BeginInvoke($msgAction) | Out-Null
        return
    }

    Update-UI ("$total updates found.") 0 $total

    $i = 0
    foreach ($u in $updates) {
        $i++
        Update-UI ("Installing update $i of $total: " + $u.Title) $i $total
        try {
            $u | Install-WindowsUpdate -AcceptAll -IgnoreReboot -ErrorAction Continue | Out-Null
            Update-UI ("Completed: " + $u.Title) $i $total
        } catch {
            Update-UI ("Failed: " + $u.Title + " | " + $_.Exception.Message) $i $total
        }
    }

    Update-UI "All updates have been processed." $total $total
})

$worker.add_RunWorkerCompleted({
    $action = [System.Action]{
        $script:closeBtn.Enabled = $true
        $script:closeBtn.Visible = $true
    }
    $script:form.BeginInvoke($action) | Out-Null
})

# Start automatically when the form is shown
$script:form.add_Shown({ $worker.RunWorkerAsync() })

# Show the form
[void]$script:form.ShowDialog()
