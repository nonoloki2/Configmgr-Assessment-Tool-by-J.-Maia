# ==============================
# Adobe Acrobat Reader Update
# Versão: 25.001.20997
# ==============================

$ErrorActionPreference = "Stop"

$Url  = "https://ardownload3.adobe.com/pub/adobe/reader/win/AcrobatDC/2500120997/AcroRdrDC2500120997_en_US.exe"
$Dest = "$env:TEMP\AcroRdrDC2500120997_en_US.exe"
$Log  = "$env:TEMP\AdobeReaderInstall.log"

try {
    Write-Output "Baixando Adobe Acrobat Reader..."
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing

    if (!(Test-Path $Dest)) {
        Write-Error "Falha no download do instalador."
        exit 1
    }

    Write-Output "Iniciando instalação silenciosa..."
    $process = Start-Process -FilePath $Dest `
        -ArgumentList "/sAll /rs /l*v `"$Log`"" `
        -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        Write-Error "Instalação falhou. ExitCode: $($process.ExitCode)"
        exit $process.ExitCode
    }

    # Validação da versão instalada
    $installed = Get-ItemProperty `
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match "Adobe Acrobat Reader" } |
        Select-Object DisplayName, DisplayVersion

    if ($installed.DisplayVersion -like "25.001.20997*") {
        Write-Output "Adobe Acrobat Reader atualizado com sucesso: $($installed.DisplayVersion)"
        exit 0
    } else {
        Write-Warning "Adobe instalado, mas versão não confirmada."
        $installed | Format-Table
        exit 0
    }

}
catch {
    Write-Error "Erro inesperado: $_"
    exit 1
}
finally {
    if (Test-Path $Dest) {
        Remove-Item $Dest -Force -ErrorAction SilentlyContinue
    }
}
