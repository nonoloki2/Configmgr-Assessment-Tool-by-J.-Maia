<#
.SYNOPSIS
    Define a associação de .msg para Outlook usando o mecanismo nativo do
    Windows (DISM Import-DefaultAppAssociations), sem ferramentas de terceiros
    e sem downloads em tempo de execução.
.PARAMETER TargetUser
    Nome de usuário (SAM) do perfil afetado — usado apenas para log.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$TargetUser
)

$logPath = "C:\Temp\FixMsgAssoc_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
New-Item -ItemType Directory -Path "C:\Temp" -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    Write-Host $line
    Add-Content -Path $logPath -Value $line
}

Write-Log "Iniciando correção de associação .msg para usuário: $TargetUser"

# --- Gera o XML de associação padrão (nativo, sem terceiros) ---
$xmlPath = "C:\Temp\DefaultAppAssociations.xml"
$xmlContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<DefaultAssociations>
    <Association Identifier=".msg" ProgId="Outlook.File.msg" ApplicationName="Microsoft Outlook" />
</DefaultAssociations>
"@
$xmlContent | Out-File -FilePath $xmlPath -Encoding UTF8
Write-Log "XML de associação gerado em $xmlPath"

# --- Aplica via DISM (componente nativo do Windows) ---
try {
    $dismResult = Dism.exe /Online /Import-DefaultAppAssociations:"$xmlPath" 2>&1
    Write-Log "DISM executado. Saída: $dismResult"
} catch {
    Write-Log "ERRO ao executar DISM: $_"
    return
}

Write-Log "=== Concluído. Log salvo em $logPath ==="
Write-Log "OBS: DISM aplica a novos perfis por padrão. Para perfis EXISTENTES, é necessário reforçar via GPO 'Configure a default associations configuration file' apontando para este mesmo XML, para reaplicar no próximo refresh de política."