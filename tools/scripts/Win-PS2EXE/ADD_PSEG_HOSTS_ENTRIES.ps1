# Verifica se está rodando como Administrador
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Erro: execute este script como Administrador." -ForegroundColor Red
    exit 1
}

# Caminho do arquivo hosts
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"

if (-not (Test-Path $hostsPath)) {
    Write-Host "Erro: arquivo hosts não encontrado em $hostsPath" -ForegroundColor Red
    exit 1
}

try {
    # Backup do arquivo hosts
    $backupPath = "$hostsPath.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item -Path $hostsPath -Destination $backupPath -Force -ErrorAction Stop
    Write-Host "Backup criado em: $backupPath" -ForegroundColor Green

    # Marcadores do bloco gerenciado
    $beginMarker = "# BEGIN PSEG"
    $endMarker   = "# END PSEG"

    # Bloco novo
    [string[]]$newBlock = @(
        $beginMarker
        "# LI Citrix access"
        "8.10.82.238`tInfrasupport.psegliny.com"
        "8.39.70.238`tInfrasupport-DR.psegliny.com"
        "8.10.82.239`tInfrasupport-VPN.psegliny.com"
        "8.39.82.239`tInfrasupport-VPN-DR.psegliny.com"
        ""
        "# Citrix Storefront URL"
        "10.184.193.58`ttsapps.pseg.com"
        ""
        "# Terminal server/storefont"
        "10.187.89.80`tNJEDISTSP100V.enterprise.pseg.com"
        "10.187.89.81`tNJEDISTSP101V.enterprise.pseg.com"
        "10.187.89.82`tNJEDISTSP102V.enterprise.pseg.com"
        "10.187.89.83`tNJEDISTSP103V.enterprise.pseg.com"
        "10.187.89.84`tNJEDISTSP104V.enterprise.pseg.com"
        "10.178.37.38`tNJNWKTSP100V.enterprise.pseg.com"
        "10.178.37.42`tNJNWKTSP101V.enterprise.pseg.com"
        "10.178.37.43`tNJNWKTSP102V.enterprise.pseg.com"
        "10.178.37.44`tNJNWKTSP103V.enterprise.pseg.com"
        "10.178.37.45`tNJNWKTSP104V.enterprise.pseg.com"
        $endMarker
    )

    # Lê o conteúdo atual
    [string[]]$currentContent = Get-Content -Path $hostsPath -ErrorAction Stop

    # Remove bloco antigo se existir
    $insideBlock = $false
    $filteredContent = New-Object System.Collections.Generic.List[string]

    foreach ($line in $currentContent) {
        if ($line.Trim() -eq $beginMarker) {
            $insideBlock = $true
            continue
        }

        if ($line.Trim() -eq $endMarker) {
            $insideBlock = $false
            continue
        }

        if (-not $insideBlock) {
            [void]$filteredContent.Add([string]$line)
        }
    }

    # Remove linhas em branco do final
    while ($filteredContent.Count -gt 0 -and [string]::IsNullOrWhiteSpace($filteredContent[$filteredContent.Count - 1])) {
        $filteredContent.RemoveAt($filteredContent.Count - 1)
    }

    # Monta conteúdo final usando array comum
    [string[]]$finalContent = @($filteredContent)

    if ($finalContent.Count -gt 0) {
        $finalContent += ""
    }

    $finalContent += $newBlock

    # Salva em ASCII
    Set-Content -Path $hostsPath -Value $finalContent -Encoding Ascii -Force -ErrorAction Stop

    Write-Host ""
    Write-Host "Arquivo hosts atualizado com sucesso." -ForegroundColor Green
    Write-Host "Bloco $beginMarker até $endMarker recriado." -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "Falha ao atualizar o arquivo hosts." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
