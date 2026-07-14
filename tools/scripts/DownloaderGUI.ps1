Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Helpers ---
function Get-FileNameFromHeadersOrUrl {
    param(
        [string]$Url,
        $Response  # System.Net.HttpWebResponse
    )

    # 1) Content-Disposition filename
    try {
        $cd = $Response.Headers["Content-Disposition"]
        if ($cd) {
            # filename*=UTF-8''... or filename="..."
            if ($cd -match "filename\*\s*=\s*UTF-8''([^;]+)") {
                return [System.Uri]::UnescapeDataString($matches[1])
            }
            if ($cd -match 'filename\s*=\s*"?([^";]+)"?') {
                return $matches[1]
            }
        }
    } catch {}

    # 2) Fallback: last segment of URL
    try {
        $u = [Uri]$Url
        $name = [System.IO.Path]::GetFileName($u.AbsolutePath)
        if (![string]::IsNullOrWhiteSpace($name)) { return $name }
    } catch {}

    # 3) Last resort
    return "download.bin"
}

function New-HttpRequest {
    param([string]$Url)

    # TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = "GET"
    $req.UserAgent = "Mozilla/5.0 (Windows; PowerShell Downloader)"
    $req.AllowAutoRedirect = $true
    $req.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

    # Proxy do sistema + credenciais padrão
    $req.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
    $req.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    $req.Credentials = [System.Net.CredentialCache]::DefaultCredentials

    return $req
}

function Download-FileWithProgress {
    param(
        [string]$Url,
        [string]$DestinationFolder,
        [System.Windows.Forms.ProgressBar]$ProgressBar,
        [System.Windows.Forms.Label]$StatusLabel
    )

    if (!(Test-Path $DestinationFolder)) {
        New-Item -Path $DestinationFolder -ItemType Directory | Out-Null
    }

    $req = New-HttpRequest -Url $Url
    $resp = $req.GetResponse()
    try {
        $fileName = Get-FileNameFromHeadersOrUrl -Url $Url -Response $resp
        $outPath  = Join-Path $DestinationFolder $fileName

        $total = $resp.ContentLength
        if ($total -le 0) {
            $ProgressBar.Style = 'Marquee'
        } else {
            $ProgressBar.Style = 'Blocks'
            $ProgressBar.Minimum = 0
            $ProgressBar.Maximum = 100
            $ProgressBar.Value = 0
        }

        $StatusLabel.Text = "Baixando: $fileName"
        $StatusLabel.Refresh()

        $inStream  = $resp.GetResponseStream()
        $outStream = [System.IO.File]::Open($outPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

        try {
            $buffer = New-Object byte[] (1024 * 256) # 256KB
            $readTotal = 0L

            while (($read = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $outStream.Write($buffer, 0, $read)
                $readTotal += $read

                if ($total -gt 0) {
                    $pct = [int](($readTotal * 100) / $total)
                    if ($pct -gt 100) { $pct = 100 }
                    $ProgressBar.Value = $pct
                    $StatusLabel.Text = "Baixando: $fileName ($pct%)"
                    $StatusLabel.Refresh()
                }

                [System.Windows.Forms.Application]::DoEvents()
            }
        }
        finally {
            $outStream.Close()
            $inStream.Close()
        }

        if ($total -le 0) {
            $ProgressBar.Style = 'Blocks'
            $ProgressBar.Value = 100
        }

        $StatusLabel.Text = "Concluído: $outPath"
        $StatusLabel.Refresh()

        return $outPath
    }
    finally {
        $resp.Close()
    }
}

# --- GUI ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Downloader (sem navegador)"
$form.Size = New-Object System.Drawing.Size(720, 260)
$form.StartPosition = "CenterScreen"
$form.TopMost = $false

$lblUrl = New-Object System.Windows.Forms.Label
$lblUrl.Text = "Cole aqui sua URL:"
$lblUrl.Location = New-Object System.Drawing.Point(12, 15)
$lblUrl.AutoSize = $true
$form.Controls.Add($lblUrl)

$txtUrl = New-Object System.Windows.Forms.TextBox
$txtUrl.Location = New-Object System.Drawing.Point(12, 35)
$txtUrl.Size = New-Object System.Drawing.Size(680, 22)
$txtUrl.Anchor = "Top,Left,Right"
$form.Controls.Add($txtUrl)

$lblPath = New-Object System.Windows.Forms.Label
$lblPath.Text = "Cole aqui o caminho que deseja salvar:"
$lblPath.Location = New-Object System.Drawing.Point(12, 70)
$lblPath.AutoSize = $true
$form.Controls.Add($lblPath)

$txtPath = New-Object System.Windows.Forms.TextBox
$txtPath.Location = New-Object System.Drawing.Point(12, 90)
$txtPath.Size = New-Object System.Drawing.Size(560, 22)
$txtPath.Anchor = "Top,Left,Right"
$txtPath.Text = "C:\Temp"
$form.Controls.Add($txtPath)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Procurar..."
$btnBrowse.Location = New-Object System.Drawing.Point(580, 88)
$btnBrowse.Size = New-Object System.Drawing.Size(112, 26)
$btnBrowse.Anchor = "Top,Right"
$form.Controls.Add($btnBrowse)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(12, 130)
$progress.Size = New-Object System.Drawing.Size(680, 18)
$progress.Anchor = "Top,Left,Right"
$form.Controls.Add($progress)

$status = New-Object System.Windows.Forms.Label
$status.Text = "Pronto."
$status.Location = New-Object System.Drawing.Point(12, 155)
$status.Size = New-Object System.Drawing.Size(680, 18)
$status.Anchor = "Top,Left,Right"
$form.Controls.Add($status)

$btnDownload = New-Object System.Windows.Forms.Button
$btnDownload.Text = "Baixar"
$btnDownload.Location = New-Object System.Drawing.Point(12, 180)
$btnDownload.Size = New-Object System.Drawing.Size(120, 30)
$form.Controls.Add($btnDownload)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Text = "Abrir pasta"
$btnOpenFolder.Location = New-Object System.Drawing.Point(140, 180)
$btnOpenFolder.Size = New-Object System.Drawing.Size(120, 30)
$btnOpenFolder.Enabled = $false
$form.Controls.Add($btnOpenFolder)

$folderDlg = New-Object System.Windows.Forms.FolderBrowserDialog

$btnBrowse.Add_Click({
    if (Test-Path $txtPath.Text) { $folderDlg.SelectedPath = $txtPath.Text }
    if ($folderDlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtPath.Text = $folderDlg.SelectedPath
    }
})

$lastSavedFolder = $null

$btnOpenFolder.Add_Click({
    if ($lastSavedFolder -and (Test-Path $lastSavedFolder)) {
        Start-Process explorer.exe $lastSavedFolder
    }
})

$btnDownload.Add_Click({
    $url = $txtUrl.Text.Trim()
    $dest = $txtPath.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($url)) {
        [System.Windows.Forms.MessageBox]::Show("Cole uma URL válida.", "Erro", "OK", "Error") | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($dest)) {
        [System.Windows.Forms.MessageBox]::Show("Informe um caminho de destino válido.", "Erro", "OK", "Error") | Out-Null
        return
    }

    $btnDownload.Enabled = $false
    $btnOpenFolder.Enabled = $false
    $progress.Value = 0
    $status.Text = "Iniciando..."
    $status.Refresh()

    try {
        $saved = Download-FileWithProgress -Url $url -DestinationFolder $dest -ProgressBar $progress -StatusLabel $status
        $lastSavedFolder = $dest
        $btnOpenFolder.Enabled = $true
        [System.Windows.Forms.MessageBox]::Show("Download concluído:`n$saved", "OK", "OK", "Information") | Out-Null
    }
    catch {
        $progress.Style = 'Blocks'
        $progress.Value = 0
        $status.Text = "Falhou: $($_.Exception.Message)"
        $status.Refresh()
        [System.Windows.Forms.MessageBox]::Show("Falhou:`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
    }
    finally {
        $btnDownload.Enabled = $true
    }
})

[void]$form.ShowDialog()
