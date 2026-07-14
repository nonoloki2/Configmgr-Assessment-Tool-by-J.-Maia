<#
GUI: Microsoft Configuration Manager Add or Remove Collection Tool
Author: ChatGPT (for José Adail Maia)
Description:
  Interface gráfica para adicionar ou remover hosts de uma collection do SCCM.
  Inclui logging detalhado em C:\Logs\SCCM_AddRemoveCollection.log
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==================== LOG FUNCTION ====================
$LogPath = "C:\Logs"
$LogFile = "$LogPath\SCCM_AddRemoveCollection.log"

if (!(Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $entry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
}

Write-Log "===== Tool launched by $env:USERNAME on $env:COMPUTERNAME ====="

# ==================== WINDOW ====================
$form = New-Object System.Windows.Forms.Form
$form.Text = "Microsoft Configuration Manager Add or Remove Collection Tool"
$form.Size = New-Object System.Drawing.Size(720, 700)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

# ==================== LABELS ====================
$lblSiteCode = New-Object System.Windows.Forms.Label
$lblSiteCode.Text = "Please provide Site Code:"
$lblSiteCode.Location = New-Object System.Drawing.Point(20, 20
