<#
==============================================================================
 SCCM-AppCreator.ps1
==============================================================================
 Interface grafica (Windows Forms) para automatizar a criacao de Aplicacoes
 no SCCM baseadas em scripts (install/uninstall .ps1 ou .bat) com deteccao
 via PowerShell lendo o registro de Uninstall (64-bit, WOW6432Node e HKCU).

 REQUISITOS:
   - Executar em uma maquina com o Console do SCCM instalado (fornece o
     modulo ConfigurationManager.psd1 via variavel de ambiente SMS_ADMIN_UI_PATH)
   - Permissao de criacao de aplicacoes no SCCM para o usuario logado
   - PowerShell 5.1+ (Windows PowerShell), executado com permissao adequada

 FLUXO ESPERADO:
   1. Testar instalacao/desinstalacao manualmente na maquina teste (voce ja faz isso)
   2. Colocar na pasta de origem (source):
        - O instalador (exe/msi) e os arquivos que os scripts precisam
        - install.ps1 ou install.bat
        - uninstall.ps1 ou uninstall.bat
   3. Abrir esta ferramenta, conectar no site, apontar a pasta, escanear
   4. (Opcional) Validar instalacao/desinstalacao/deteccao na propria maquina teste
   5. Criar a aplicacao no SCCM com um clique
==============================================================================
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ----------------------------------------------------------------------------
# FUNCOES DE LOGICA (separadas da GUI para poderem ser reaproveitadas/testadas)
# ----------------------------------------------------------------------------

function Get-CleanPath {
    <#
        Normaliza caminhos colados de fontes como a barra de enderecos do
        Explorer. O Windows envolve o caminho em aspas quando ele contem
        espacos (comum em nomes de pasta), e isso vira parte literal da
        string ao colar - o Test-Path falha silenciosamente por causa disso.
        Remove tambem espacos/quebras de linha nas pontas e uma barra final.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $clean = $Path.Trim()
    # Remove aspas retas e "curvas" (tipograficas) nas pontas, se existirem
    $clean = $clean.Trim([char]'"', [char]"'", [char]0x201C, [char]0x201D, [char]0x2018, [char]0x2019)
    $clean = $clean.Trim()
    # Remove barra invertida final (exceto se for so a raiz "\\servidor\share")
    if ($clean.Length -gt 2 -and $clean.EndsWith('\')) {
        $clean = $clean.TrimEnd('\')
    }
    return $clean
}

function Copy-SourceViaInteractiveSession {
    <#
        Contorna o problema de a conta que roda este script (ex: conta de
        servico do CyberArk, cuja senha ninguem digita/conhece) nao ter
        acesso ao share de arquivos, enquanto o usuario JA LOGADO na sessao
        interativa (o mesmo dono do explorer.exe, que abre a pasta numa boa)
        tem acesso.

        NAO PRECISA DE SENHA: cria uma Tarefa Agendada configurada para
        rodar "como esse usuario logado" (LogonType Interactive). O Windows
        reaproveita o token da sessao ja aberta - por isso nao pede senha.
        Essa tarefa roda com a identidade do usuario interativo e copia a
        pasta de origem para uma pasta local temporaria, que o processo
        elevado (rodando como conta de servico) consegue ler normalmente
        depois, ja que e so um arquivo local.

        Requisitos: o usuario precisa estar com sessao ativa (explorer.exe
        rodando) na mesma maquina, e a conta atual precisa poder criar
        tarefas agendadas (normalmente ok, ja que esta rodando elevada).
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath
    )

    try {
        $explorerProc = Get-Process -Name explorer -IncludeUserName -ErrorAction Stop | Select-Object -First 1
    }
    catch {
        return [PSCustomObject]@{ Sucesso = $false; CaminhoEfetivo = $null; Mensagem = "Nao foi possivel identificar o usuario da sessao interativa (falha ao consultar explorer.exe). Voce precisa estar rodando este script com privilegios suficientes para ver o usuario de outros processos, e ter uma sessao interativa ativa nesta maquina." }
    }

    if (-not $explorerProc -or -not $explorerProc.UserName) {
        return [PSCustomObject]@{ Sucesso = $false; CaminhoEfetivo = $null; Mensagem = "Nenhuma sessao interativa (explorer.exe) encontrada nesta maquina." }
    }

    $interactiveUser = $explorerProc.UserName
    $destFolder = Join-Path $env:TEMP ("SCCMAppSrc_" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $statusFile = Join-Path $destFolder "_status.txt"
    $taskName   = "SCCMAppCreator_Copy_" + [guid]::NewGuid().ToString('N').Substring(0,8)
    $helperScript = Join-Path $env:TEMP "$taskName.ps1"

    try {
        # Nao criamos $destFolder antecipadamente: se ele ja existir, o Copy-Item
        # copia a pasta de origem para DENTRO dele (como subpasta), em vez de
        # usar ele como o destino final. Deixando o Copy-Item criar o
        # destino do zero, o conteudo fica direto em $destFolder.

        $helperContent = @"
try {
    Copy-Item -LiteralPath '$SourcePath' -Destination '$destFolder' -Recurse -Force -ErrorAction Stop
    New-Item -Path '$destFolder' -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    'OK' | Out-File -FilePath '$statusFile' -Encoding ascii -Force
}
catch {
    New-Item -Path '$destFolder' -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    `$_.Exception.Message | Out-File -FilePath '$statusFile' -Encoding ascii -Force
}
"@
        Set-Content -Path $helperScript -Value $helperContent -Encoding UTF8 -Force

        $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$helperScript`""
        $principal = New-ScheduledTaskPrincipal -UserId $interactiveUser -LogonType Interactive -RunLevel Limited

        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        $timeoutSegundos = 60
        $decorrido = 0
        do {
            Start-Sleep -Seconds 1
            $decorrido++
            $estado = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
        } while ($estado -eq 'Running' -and $decorrido -lt $timeoutSegundos)

        Start-Sleep -Milliseconds 500  # da um tempinho pro arquivo de status terminar de gravar
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -Path $helperScript -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $statusFile)) {
        return [PSCustomObject]@{
            Sucesso = $false; CaminhoEfetivo = $null
            Mensagem = "A tarefa nao concluiu a tempo ou nao gerou resultado. Verifique se '$interactiveUser' realmente tem uma sessao interativa ativa e acesso a essa pasta."
        }
    }

    $status = (Get-Content -LiteralPath $statusFile -Raw).Trim()
    Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue

    if ($status -eq 'OK') {
        return [PSCustomObject]@{
            Sucesso = $true; CaminhoEfetivo = $destFolder
            Mensagem = "Pasta copiada com sucesso usando a sessao interativa de '$interactiveUser' (sem senha)."
        }
    }
    else {
        return [PSCustomObject]@{ Sucesso = $false; CaminhoEfetivo = $null; Mensagem = "Falha ao copiar como '$interactiveUser': $status" }
    }
}


function Resolve-SourceAccess {
    <#
        Garante acesso de LEITURA a pasta de origem para fins de escaneamento/teste.

        Se $Credential for informado, mapeia um PSDrive temporario usando essa
        credencial (util quando o script roda com uma conta de servico/SCCM
        que nao tem permissao no share de arquivos, mas o usuario tem).

        Retorna um objeto com:
          Sucesso           - bool
          CaminhoEfetivo    - caminho a usar para Test-Path/Get-ChildItem/Copy-Item
          Mensagem          - detalhe do erro, se houver

        O caminho original (UNC real) deve ser guardado a parte para uso no
        -ContentLocation do SCCM, que nao deve usar o drive temporario.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [System.Management.Automation.PSCredential]$Credential
    )

    # Remove mapeamento anterior, se existir, para evitar conflito de nome
    if (Get-PSDrive -Name 'SCCMSRC' -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name 'SCCMSRC' -Force -ErrorAction SilentlyContinue
    }

    if ($Credential) {
        try {
            New-PSDrive -Name 'SCCMSRC' -PSProvider FileSystem -Root $Path -Credential $Credential -Scope Global -ErrorAction Stop | Out-Null
            return [PSCustomObject]@{ Sucesso = $true; CaminhoEfetivo = 'SCCMSRC:\'; Mensagem = "Acesso via credencial alternativa OK." }
        }
        catch {
            return [PSCustomObject]@{ Sucesso = $false; CaminhoEfetivo = $null; Mensagem = $_.Exception.Message }
        }
    }
    else {
        if (Test-Path -LiteralPath $Path) {
            return [PSCustomObject]@{ Sucesso = $true; CaminhoEfetivo = $Path; Mensagem = "Acesso com a conta atual OK." }
        }
        else {
            return [PSCustomObject]@{ Sucesso = $false; CaminhoEfetivo = $null; Mensagem = "Test-Path retornou falso (sem detalhe de erro adicional)." }
        }
    }
}


function Get-InstallCommandLine {
    <#
        Verifica na pasta de origem se existe install.ps1/uninstall.ps1 ou
        install.bat/uninstall.bat e retorna a linha de comando pronta para
        os campos "Program"/"Uninstall Program" do SCCM.
        Prioridade: .ps1 primeiro, depois .bat.
    #>
    param(
        [Parameter(Mandatory)][string]$FolderPath,
        [Parameter(Mandatory)][ValidateSet('install','uninstall')][string]$Action
    )

    $ps1Path = Join-Path $FolderPath "$Action.ps1"
    $batPath = Join-Path $FolderPath "$Action.bat"

    if (Test-Path -LiteralPath $ps1Path) {
        return [PSCustomObject]@{
            Encontrado = $true
            Tipo       = 'PowerShell'
            Arquivo    = "$Action.ps1"
            Comando    = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `".\$Action.ps1`""
        }
    }
    elseif (Test-Path -LiteralPath $batPath) {
        return [PSCustomObject]@{
            Encontrado = $true
            Tipo       = 'Batch'
            Arquivo    = "$Action.bat"
            Comando    = "cmd.exe /c `".\$Action.bat`""
        }
    }
    else {
        return [PSCustomObject]@{
            Encontrado = $false
            Tipo       = $null
            Arquivo    = $null
            Comando    = $null
        }
    }
}

function New-DetectionScriptText {
    <#
        Gera o TEXTO do script de deteccao em PowerShell que sera colocado
        no Deployment Type do SCCM (Detection Method = Script).
        Varre:
          - HKLM\...\Uninstall            (apps 64-bit nativos)
          - HKLM\...\WOW6432Node\Uninstall (apps 32-bit em SO 64-bit)
          - HKCU\...\Uninstall            (apps instalados por usuario)
    #>
    param(
        [Parameter(Mandatory)][string]$DisplayNamePattern,
        [Parameter(Mandatory)][string]$MinVersion
    )

    return @"
`$ErrorActionPreference = 'SilentlyContinue'
`$displayNamePattern = '$DisplayNamePattern'
`$minVersion = [version]'$MinVersion'

`$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

`$apps = Get-ItemProperty -Path `$uninstallPaths |
    Where-Object { `$_.DisplayName -like "*`$displayNamePattern*" -and `$_.DisplayVersion }

foreach (`$app in `$apps) {
    try {
        `$installedVersion = [version](`$app.DisplayVersion -replace '[^0-9.]', '')
        if (`$installedVersion -ge `$minVersion) {
            Write-Output "Instalado"
            break
        }
    }
    catch { }
}
"@
}

function Connect-ToSCCM {
    param(
        [Parameter(Mandatory)][string]$SiteServer,
        [Parameter(Mandatory)][string]$SiteCode
    )

    try {
        if (-not $env:SMS_ADMIN_UI_PATH) {
            throw "Variavel SMS_ADMIN_UI_PATH nao encontrada. O Console do SCCM precisa estar instalado nesta maquina."
        }

        if (-not (Get-Module ConfigurationManager)) {
            $modulePath = Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1'
            Import-Module $modulePath -ErrorAction Stop
        }

        if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null
        }

        Set-Location "$($SiteCode):\"
        return [PSCustomObject]@{ Sucesso = $true; Mensagem = "Conectado a $SiteServer ($SiteCode)" }
    }
    catch {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = $_.Exception.Message }
    }
}

function Get-CMAppCreatorHelperScriptText {
    <#
        Helper permanente do SCCM App Creator.
        Ele e executado pelo recurso Run Scripts do Configuration Manager no
        cliente alvo. O script roda no contexto do cliente SCCM (SYSTEM), sem
        WinRM, sem LAPS e sem CyberArk para a maquina teste.
    #>

    return @'
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Ping','RunDetection','RunSourceScript','InventoryInstalledSoftware')]
    [string]$Action,

    [string]$DetectionScriptB64 = '',
    [string]$SourcePath = '',
    [string]$ScriptType = '',
    [string]$ScriptFile = ''
)

$ErrorActionPreference = 'Stop'

function Get-ExecutionIdentity {
    try { return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
    catch { return (& whoami.exe 2>$null) }
}

switch ($Action) {
    'Ping' {
        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            Identity     = Get-ExecutionIdentity
            Timestamp    = (Get-Date).ToString('s')
            Mode         = 'SCCM Run Script'
        } | ConvertTo-Json -Compress
    }

    'RunDetection' {
        if ([string]::IsNullOrWhiteSpace($DetectionScriptB64)) {
            throw 'DetectionScriptB64 nao informado.'
        }

        $bytes = [Convert]::FromBase64String($DetectionScriptB64)
        $text  = [Text.Encoding]::UTF8.GetString($bytes)
        $sb    = [ScriptBlock]::Create($text)

        $result = & $sb 2>&1 | Out-String
        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            Identity     = Get-ExecutionIdentity
            Result       = $result.Trim()
        } | ConvertTo-Json -Compress
    }

    'RunSourceScript' {
        if ([string]::IsNullOrWhiteSpace($SourcePath)) { throw 'SourcePath nao informado.' }
        if ([string]::IsNullOrWhiteSpace($ScriptFile)) { throw 'ScriptFile nao informado.' }
        if (-not (Test-Path -LiteralPath $SourcePath)) {
            throw "SYSTEM nao conseguiu acessar a pasta de origem: $SourcePath"
        }

        Push-Location -LiteralPath $SourcePath
        try {
            if ($ScriptType -eq 'PowerShell') {
                $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $SourcePath $ScriptFile) 2>&1 | Out-String
            }
            elseif ($ScriptType -eq 'Batch') {
                $output = & cmd.exe /c ('"{0}"' -f (Join-Path $SourcePath $ScriptFile)) 2>&1 | Out-String
            }
            else {
                throw "Tipo de script nao suportado: $ScriptType"
            }
        }
        finally {
            Pop-Location
        }

        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            Identity     = Get-ExecutionIdentity
            Script       = $ScriptFile
            Output       = $output.Trim()
        } | ConvertTo-Json -Compress
    }

    'InventoryInstalledSoftware' {
        $paths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )

        Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.DisplayName) } |
            Select-Object DisplayName, DisplayVersion, Publisher, PSPath, UninstallString, QuietUninstallString |
            Sort-Object DisplayName |
            ConvertTo-Json -Compress -Depth 3
    }
}
'@
}

function Ensure-CMAppCreatorHelperScript {
    param(
        [string]$ScriptName = 'SCCM-AppCreator-SystemHelper'
    )

    try {
        $helper = Get-CMScript -ScriptName $ScriptName -Fast -ErrorAction SilentlyContinue |
            Where-Object { $_.ScriptName -eq $ScriptName } |
            Select-Object -First 1

        if (-not $helper) {
            $helperText = Get-CMAppCreatorHelperScriptText
            New-CMScript -ScriptName $ScriptName -ScriptText $helperText -Fast -ErrorAction Stop | Out-Null
            Start-Sleep -Milliseconds 500
            $helper = Get-CMScript -ScriptName $ScriptName -Fast -ErrorAction Stop |
                Where-Object { $_.ScriptName -eq $ScriptName } |
                Select-Object -First 1
        }

        if (-not $helper) {
            throw "Nao foi possivel localizar/criar o helper '$ScriptName'."
        }

        # ApprovalState 3 = Approved. Em ambientes onde o autor nao pode
        # aprovar o proprio script, a tentativa abaixo falha e a GUI explica
        # que a aprovacao precisa ser feita uma unica vez por outro admin.
        if ([int]$helper.ApprovalState -ne 3) {
            try {
                Approve-CMScript -InputObject $helper -Comment 'Helper do SCCM App Creator para testes como SYSTEM.' -Confirm:$false -ErrorAction Stop | Out-Null
                Start-Sleep -Milliseconds 500
                $helper = Get-CMScript -ScriptName $ScriptName -Fast -ErrorAction Stop |
                    Where-Object { $_.ScriptName -eq $ScriptName } |
                    Select-Object -First 1
            }
            catch {
                return [PSCustomObject]@{
                    Sucesso = $false
                    Helper  = $helper
                    PrecisaAprovacao = $true
                    Mensagem = "O helper '$ScriptName' foi criado, mas ainda precisa ser APROVADO no SCCM em Software Library > Scripts. Por padrao, o autor nao pode aprovar o proprio script. Depois de aprovado, clique novamente em Conectar via SCCM / SYSTEM."
                }
            }
        }

        if ([int]$helper.ApprovalState -ne 3) {
            return [PSCustomObject]@{
                Sucesso = $false
                Helper  = $helper
                PrecisaAprovacao = $true
                Mensagem = "O helper '$ScriptName' existe, mas ainda nao esta aprovado no SCCM."
            }
        }

        return [PSCustomObject]@{ Sucesso = $true; Helper = $helper; PrecisaAprovacao = $false; Mensagem = "Helper '$ScriptName' aprovado e pronto." }
    }
    catch {
        return [PSCustomObject]@{ Sucesso = $false; Helper = $null; PrecisaAprovacao = $false; Mensagem = $_.Exception.Message }
    }
}

function Wait-CMScriptResult {
    param(
        [Parameter(Mandatory)][uint32]$OperationID,
        [Parameter(Mandatory)][string]$SiteServer,
        [Parameter(Mandatory)][string]$SiteCode,
        [int]$TimeoutSeconds = 90
    )

    $namespace = "root\SMS\site_$SiteCode"
    $elapsed = 0

    do {
        try {
            $status = Get-CimInstance -ComputerName $SiteServer -Namespace $namespace -ClassName SMS_ScriptsExecutionStatus -Filter "ClientOperationID = '$OperationID'" -ErrorAction Stop |
                Sort-Object LastUpdateTime -Descending |
                Select-Object -First 1
        }
        catch {
            throw "Falha consultando o resultado do Run Script no SMS Provider: $($_.Exception.Message)"
        }

        if ($status) { return $status }

        Start-Sleep -Seconds 2
        $elapsed += 2
        [System.Windows.Forms.Application]::DoEvents()
    } while ($elapsed -lt $TimeoutSeconds)

    throw "Timeout aguardando retorno da maquina pelo SCCM apos $TimeoutSeconds segundos. Verifique se o cliente esta online e os logs Scripts.log/CcmMessaging.log."
}

function Invoke-CMSystemAction {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][ValidateSet('Ping','RunDetection','RunSourceScript','InventoryInstalledSoftware')][string]$Action,
        [string]$DetectionScriptText,
        [string]$SourcePath,
        [PSCustomObject]$ScriptInfo,
        [int]$TimeoutSeconds = 90
    )

    if (-not $script:SiteServer -or -not $script:SiteCode) {
        throw 'Conecte primeiro ao SCCM no grupo 1 da interface.'
    }

    $device = Get-CMDevice -Name $ComputerName -Fast -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $ComputerName } |
        Select-Object -First 1

    if (-not $device) {
        throw "A maquina '$ComputerName' nao foi encontrada como device no SCCM."
    }

    $helperResult = Ensure-CMAppCreatorHelperScript
    if (-not $helperResult.Sucesso) {
        throw $helperResult.Mensagem
    }

    $params = @{ Action = $Action }

    if ($Action -eq 'RunDetection') {
        if ([string]::IsNullOrWhiteSpace($DetectionScriptText)) { throw 'Script de deteccao vazio.' }
        $params.DetectionScriptB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($DetectionScriptText))
    }
    elseif ($Action -eq 'RunSourceScript') {
        if (-not $ScriptInfo) { throw 'Informacoes do script de install/uninstall nao fornecidas.' }
        if ([string]::IsNullOrWhiteSpace($SourcePath)) { throw 'Pasta de origem nao informada.' }
        $params.SourcePath = $SourcePath
        $params.ScriptType = $ScriptInfo.Tipo
        $params.ScriptFile = $ScriptInfo.Arquivo
    }

    $invoke = Invoke-CMScript -ScriptGuid $helperResult.Helper.ScriptGuid -Device $device -ScriptParameter $params -PassThru -Confirm:$false -ErrorAction Stop
    if (-not $invoke -or -not $invoke.OperationID) {
        throw 'O SCCM nao retornou OperationID para a execucao do Run Script.'
    }

    return Wait-CMScriptResult -OperationID ([uint32]$invoke.OperationID) -SiteServer $script:SiteServer -SiteCode $script:SiteCode -TimeoutSeconds $TimeoutSeconds
}

function Connect-RemoteTestMachine {
    <#
        Valida a maquina teste pelo proprio SCCM e executa um Ping pelo recurso
        Run Scripts. Nao abre PSSession e nao solicita credenciais da estacao.
    #>
    param([Parameter(Mandatory)][string]$ComputerName)

    try {
        $status = Invoke-CMSystemAction -ComputerName $ComputerName -Action Ping -TimeoutSeconds 60
        $output = $status.ScriptOutput
        $identity = $null
        try {
            $json = $output | ConvertFrom-Json -ErrorAction Stop
            $identity = $json.Identity
        } catch {}

        return [PSCustomObject]@{
            Sucesso  = $true
            Mensagem = if ($identity) { "Maquina respondeu pelo SCCM. Contexto remoto: $identity" } else { "Maquina respondeu pelo SCCM Run Script." }
            Output   = $output
        }
    }
    catch {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = $_.Exception.Message; Output = $null }
    }
}

function Invoke-RemoteScriptAction {
    <#
        Compatibilidade com os botoes existentes. Agora a execucao remota e
        enviada pelo SCCM e roda no cliente como SYSTEM.

        Observacao: a conta SYSTEM da maquina teste precisa conseguir ler a
        pasta UNC de origem. Caso o share nao permita acesso para a conta do
        computador/Dominio Computers, a GUI exibira o erro devolvido pelo helper.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][PSCustomObject]$ScriptInfo
    )

    $status = Invoke-CMSystemAction -ComputerName $ComputerName -Action RunSourceScript -SourcePath $SourceFolder -ScriptInfo $ScriptInfo -TimeoutSeconds 300
    return $status.ScriptOutput
}

function Invoke-RemoteDetection {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$DetectionScriptText
    )

    $status = Invoke-CMSystemAction -ComputerName $ComputerName -Action RunDetection -DetectionScriptText $DetectionScriptText -TimeoutSeconds 90
    return $status.ScriptOutput
}

function New-SCCMScriptApplication {
    param(
        [Parameter(Mandatory)][string]$AppName,
        [string]$Publisher,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$InstallCommand,
        [Parameter(Mandatory)][string]$UninstallCommand,
        [Parameter(Mandatory)][string]$DetectionScript
    )

    try {
        New-CMApplication -Name $AppName -Publisher $Publisher -SoftwareVersion $Version -ErrorAction Stop | Out-Null

        Add-CMScriptDeploymentType `
            -ApplicationName $AppName `
            -DeploymentTypeName "$AppName - Instalacao via Script" `
            -ContentLocation $SourceFolder `
            -InstallCommand $InstallCommand `
            -UninstallCommand $UninstallCommand `
            -ScriptLanguage 'PowerShell' `
            -ScriptText $DetectionScript `
            -InstallationBehaviorType InstallForSystem `
            -LogonRequirementType WhetherOrNotUserLoggedOn `
            -UserInteractionMode Hidden `
            -ErrorAction Stop | Out-Null

        return [PSCustomObject]@{ Sucesso = $true; Mensagem = "Aplicacao '$AppName' criada com sucesso no SCCM." }
    }
    catch {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = $_.Exception.Message }
    }
}

# ----------------------------------------------------------------------------
# ESTADO GLOBAL (guarda o que foi escaneado para reaproveitar nos testes/criacao)
# ----------------------------------------------------------------------------
$script:InstallInfo   = $null
$script:UninstallInfo = $null
$script:DetectionText = $null
$script:TestSession   = $null # mantido por compatibilidade; WinRM nao e mais usado
$script:RemoteTestConnected = $false
$script:RemoteTestComputer  = $null
$script:SiteServer          = $null
$script:SiteCode            = $null
$script:SourceCredential  = $null
$script:SourceMappedDrive = $null   # nome do PSDrive temporario, se usado
$script:EffectiveSourcePath = $null # caminho usado de fato para ler arquivos (UNC ou drive mapeado)
$script:OriginalSourcePath  = $null # caminho UNC real, sempre usado no -ContentLocation do SCCM

# ----------------------------------------------------------------------------
# GUI
# ----------------------------------------------------------------------------
$form                  = New-Object System.Windows.Forms.Form
$form.Text             = "SCCM App Creator - Aplicacoes baseadas em Script"
$form.Size             = New-Object System.Drawing.Size(720, 850)
$form.StartPosition    = "CenterScreen"
$form.FormBorderStyle  = 'FixedDialog'
$form.MaximizeBox      = $false

# --- Grupo: Conexao SCCM ---
$grpConn = New-Object System.Windows.Forms.GroupBox
$grpConn.Text = "1. Conexao com o SCCM"
$grpConn.Location = New-Object System.Drawing.Point(10, 10)
$grpConn.Size = New-Object System.Drawing.Size(690, 90)
$form.Controls.Add($grpConn)

$lblServer = New-Object System.Windows.Forms.Label
$lblServer.Text = "Site Server:"
$lblServer.Location = New-Object System.Drawing.Point(10, 25)
$lblServer.Size = New-Object System.Drawing.Size(80, 20)
$grpConn.Controls.Add($lblServer)

$txtServer = New-Object System.Windows.Forms.TextBox
$txtServer.Location = New-Object System.Drawing.Point(95, 22)
$txtServer.Size = New-Object System.Drawing.Size(220, 20)
$grpConn.Controls.Add($txtServer)

$lblSiteCode = New-Object System.Windows.Forms.Label
$lblSiteCode.Text = "Site Code:"
$lblSiteCode.Location = New-Object System.Drawing.Point(330, 25)
$lblSiteCode.Size = New-Object System.Drawing.Size(70, 20)
$grpConn.Controls.Add($lblSiteCode)

$txtSiteCode = New-Object System.Windows.Forms.TextBox
$txtSiteCode.Location = New-Object System.Drawing.Point(405, 22)
$txtSiteCode.Size = New-Object System.Drawing.Size(80, 20)
$grpConn.Controls.Add($txtSiteCode)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "Conectar"
$btnConnect.Location = New-Object System.Drawing.Point(500, 20)
$btnConnect.Size = New-Object System.Drawing.Size(90, 25)
$grpConn.Controls.Add($btnConnect)

$lblConnStatus = New-Object System.Windows.Forms.Label
$lblConnStatus.Text = "Nao conectado."
$lblConnStatus.ForeColor = 'Red'
$lblConnStatus.Location = New-Object System.Drawing.Point(10, 55)
$lblConnStatus.Size = New-Object System.Drawing.Size(650, 20)
$grpConn.Controls.Add($lblConnStatus)

# --- Grupo: Dados da Aplicacao ---
$grpApp = New-Object System.Windows.Forms.GroupBox
$grpApp.Text = "2. Dados da Aplicacao"
$grpApp.Location = New-Object System.Drawing.Point(10, 110)
$grpApp.Size = New-Object System.Drawing.Size(690, 240)
$form.Controls.Add($grpApp)

$lblAppName = New-Object System.Windows.Forms.Label
$lblAppName.Text = "Nome da Aplicacao:"
$lblAppName.Location = New-Object System.Drawing.Point(10, 25)
$lblAppName.Size = New-Object System.Drawing.Size(120, 20)
$grpApp.Controls.Add($lblAppName)

$txtAppName = New-Object System.Windows.Forms.TextBox
$txtAppName.Location = New-Object System.Drawing.Point(140, 22)
$txtAppName.Size = New-Object System.Drawing.Size(350, 20)
$grpApp.Controls.Add($txtAppName)

$lblPublisher = New-Object System.Windows.Forms.Label
$lblPublisher.Text = "Fabricante:"
$lblPublisher.Location = New-Object System.Drawing.Point(10, 55)
$lblPublisher.Size = New-Object System.Drawing.Size(120, 20)
$grpApp.Controls.Add($lblPublisher)

$txtPublisher = New-Object System.Windows.Forms.TextBox
$txtPublisher.Location = New-Object System.Drawing.Point(140, 52)
$txtPublisher.Size = New-Object System.Drawing.Size(350, 20)
$grpApp.Controls.Add($txtPublisher)

$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = "Versao (ex: 1.2.3):"
$lblVersion.Location = New-Object System.Drawing.Point(10, 85)
$lblVersion.Size = New-Object System.Drawing.Size(120, 20)
$grpApp.Controls.Add($lblVersion)

$txtVersion = New-Object System.Windows.Forms.TextBox
$txtVersion.Location = New-Object System.Drawing.Point(140, 82)
$txtVersion.Size = New-Object System.Drawing.Size(150, 20)
$grpApp.Controls.Add($txtVersion)

$lblDetectPattern = New-Object System.Windows.Forms.Label
$lblDetectPattern.Text = "Padrao DisplayName (registro):"
$lblDetectPattern.Location = New-Object System.Drawing.Point(300, 85)
$lblDetectPattern.Size = New-Object System.Drawing.Size(190, 20)
$grpApp.Controls.Add($lblDetectPattern)

$txtDetectPattern = New-Object System.Windows.Forms.TextBox
$txtDetectPattern.Location = New-Object System.Drawing.Point(495, 82)
$txtDetectPattern.Size = New-Object System.Drawing.Size(190, 20)
$grpApp.Controls.Add($txtDetectPattern)

$lblSourceFolder = New-Object System.Windows.Forms.Label
$lblSourceFolder.Text = "Pasta de Origem (source):"
$lblSourceFolder.Location = New-Object System.Drawing.Point(10, 115)
$lblSourceFolder.Size = New-Object System.Drawing.Size(150, 20)
$grpApp.Controls.Add($lblSourceFolder)

$txtSourceFolder = New-Object System.Windows.Forms.TextBox
$txtSourceFolder.Location = New-Object System.Drawing.Point(140, 112)
$txtSourceFolder.Size = New-Object System.Drawing.Size(540, 20)
$txtSourceFolder.ShortcutsEnabled = $true
$grpApp.Controls.Add($txtSourceFolder)

$btnPasteFolder = New-Object System.Windows.Forms.Button
$btnPasteFolder.Text = "Colar"
$btnPasteFolder.Location = New-Object System.Drawing.Point(140, 138)
$btnPasteFolder.Size = New-Object System.Drawing.Size(60, 23)
$grpApp.Controls.Add($btnPasteFolder)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Procurar..."
$btnBrowse.Location = New-Object System.Drawing.Point(205, 138)
$btnBrowse.Size = New-Object System.Drawing.Size(80, 23)
$grpApp.Controls.Add($btnBrowse)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = "Escanear Pasta"
$btnScan.Location = New-Object System.Drawing.Point(290, 138)
$btnScan.Size = New-Object System.Drawing.Size(120, 23)
$grpApp.Controls.Add($btnScan)

$btnUseInteractiveSession = New-Object System.Windows.Forms.Button
$btnUseInteractiveSession.Text = "Usar sessao logada (sem senha)"
$btnUseInteractiveSession.Location = New-Object System.Drawing.Point(140, 165)
$btnUseInteractiveSession.Size = New-Object System.Drawing.Size(220, 23)
$grpApp.Controls.Add($btnUseInteractiveSession)

$btnSourceCred = New-Object System.Windows.Forms.Button
$btnSourceCred.Text = "Ou informar credencial..."
$btnSourceCred.Location = New-Object System.Drawing.Point(365, 165)
$btnSourceCred.Size = New-Object System.Drawing.Size(150, 23)
$grpApp.Controls.Add($btnSourceCred)

$btnClearSourceCred = New-Object System.Windows.Forms.Button
$btnClearSourceCred.Text = "Limpar"
$btnClearSourceCred.Location = New-Object System.Drawing.Point(520, 165)
$btnClearSourceCred.Size = New-Object System.Drawing.Size(55, 23)
$grpApp.Controls.Add($btnClearSourceCred)

$lblSourceCredStatus = New-Object System.Windows.Forms.Label
$lblSourceCredStatus.Text = "Acesso a pasta: usando a conta atual do script."
$lblSourceCredStatus.ForeColor = 'Gray'
$lblSourceCredStatus.Location = New-Object System.Drawing.Point(10, 192)
$lblSourceCredStatus.Size = New-Object System.Drawing.Size(670, 18)
$grpApp.Controls.Add($lblSourceCredStatus)

$lblScanResult = New-Object System.Windows.Forms.Label
$lblScanResult.Text = "Instalacao: -- | Desinstalacao: --"
$lblScanResult.Location = New-Object System.Drawing.Point(10, 210)
$lblScanResult.Size = New-Object System.Drawing.Size(670, 20)
$grpApp.Controls.Add($lblScanResult)

# --- Grupo: Maquina de Teste Remota (CyberArk / conta de servico sem acesso a maquina teste) ---
$grpRemote = New-Object System.Windows.Forms.GroupBox
$grpRemote.Text = "3. Maquina de Teste (Remota - opcional, use quando o script roda no servidor)"
$grpRemote.Location = New-Object System.Drawing.Point(10, 360)
$grpRemote.Size = New-Object System.Drawing.Size(690, 70)
$form.Controls.Add($grpRemote)

$lblTestMachine = New-Object System.Windows.Forms.Label
$lblTestMachine.Text = "Nome/IP da maquina teste:"
$lblTestMachine.Location = New-Object System.Drawing.Point(10, 25)
$lblTestMachine.Size = New-Object System.Drawing.Size(150, 20)
$grpRemote.Controls.Add($lblTestMachine)

$txtTestMachine = New-Object System.Windows.Forms.TextBox
$txtTestMachine.Location = New-Object System.Drawing.Point(165, 22)
$txtTestMachine.Size = New-Object System.Drawing.Size(200, 20)
$grpRemote.Controls.Add($txtTestMachine)

$btnConnectRemote = New-Object System.Windows.Forms.Button
$btnConnectRemote.Text = "Conectar via SCCM / SYSTEM"
$btnConnectRemote.Location = New-Object System.Drawing.Point(375, 21)
$btnConnectRemote.Size = New-Object System.Drawing.Size(170, 23)
$grpRemote.Controls.Add($btnConnectRemote)

$btnDisconnectRemote = New-Object System.Windows.Forms.Button
$btnDisconnectRemote.Text = "Desconectar"
$btnDisconnectRemote.Location = New-Object System.Drawing.Point(555, 21)
$btnDisconnectRemote.Size = New-Object System.Drawing.Size(125, 23)
$grpRemote.Controls.Add($btnDisconnectRemote)

$lblRemoteStatus = New-Object System.Windows.Forms.Label
$lblRemoteStatus.Text = "Sem maquina teste conectada pelo SCCM (testes rodarao localmente)."
$lblRemoteStatus.ForeColor = 'Gray'
$lblRemoteStatus.Location = New-Object System.Drawing.Point(10, 48)
$lblRemoteStatus.Size = New-Object System.Drawing.Size(670, 18)
$grpRemote.Controls.Add($lblRemoteStatus)

# --- Grupo: Comandos gerados ---
$grpCmds = New-Object System.Windows.Forms.GroupBox
$grpCmds.Text = "4. Linhas geradas (SCCM Deployment Type)"
$grpCmds.Location = New-Object System.Drawing.Point(10, 440)
$grpCmds.Size = New-Object System.Drawing.Size(690, 130)
$form.Controls.Add($grpCmds)

$lblInstallCmd = New-Object System.Windows.Forms.Label
$lblInstallCmd.Text = "Install command:"
$lblInstallCmd.Location = New-Object System.Drawing.Point(10, 22)
$lblInstallCmd.Size = New-Object System.Drawing.Size(100, 20)
$grpCmds.Controls.Add($lblInstallCmd)

$txtInstallCmd = New-Object System.Windows.Forms.TextBox
$txtInstallCmd.Location = New-Object System.Drawing.Point(10, 42)
$txtInstallCmd.Size = New-Object System.Drawing.Size(670, 20)
$txtInstallCmd.ReadOnly = $true
$grpCmds.Controls.Add($txtInstallCmd)

$lblUninstallCmd = New-Object System.Windows.Forms.Label
$lblUninstallCmd.Text = "Uninstall command:"
$lblUninstallCmd.Location = New-Object System.Drawing.Point(10, 68)
$lblUninstallCmd.Size = New-Object System.Drawing.Size(120, 20)
$grpCmds.Controls.Add($lblUninstallCmd)

$txtUninstallCmd = New-Object System.Windows.Forms.TextBox
$txtUninstallCmd.Location = New-Object System.Drawing.Point(10, 88)
$txtUninstallCmd.Size = New-Object System.Drawing.Size(670, 20)
$txtUninstallCmd.ReadOnly = $true
$grpCmds.Controls.Add($txtUninstallCmd)

# --- Grupo: Testes (local ou remoto, dependendo da sessao) ---
$grpTest = New-Object System.Windows.Forms.GroupBox
$grpTest.Text = "5. Testes (local por padrao, ou na maquina remota se conectada acima)"
$grpTest.Location = New-Object System.Drawing.Point(10, 580)
$grpTest.Size = New-Object System.Drawing.Size(690, 60)
$form.Controls.Add($grpTest)

$btnTestInstall = New-Object System.Windows.Forms.Button
$btnTestInstall.Text = "Testar Instalacao"
$btnTestInstall.Location = New-Object System.Drawing.Point(10, 22)
$btnTestInstall.Size = New-Object System.Drawing.Size(140, 25)
$grpTest.Controls.Add($btnTestInstall)

$btnTestUninstall = New-Object System.Windows.Forms.Button
$btnTestUninstall.Text = "Testar Desinstalacao"
$btnTestUninstall.Location = New-Object System.Drawing.Point(160, 22)
$btnTestUninstall.Size = New-Object System.Drawing.Size(140, 25)
$grpTest.Controls.Add($btnTestUninstall)

$btnTestDetection = New-Object System.Windows.Forms.Button
$btnTestDetection.Text = "Testar Deteccao"
$btnTestDetection.Location = New-Object System.Drawing.Point(310, 22)
$btnTestDetection.Size = New-Object System.Drawing.Size(140, 25)
$grpTest.Controls.Add($btnTestDetection)

$btnCreate = New-Object System.Windows.Forms.Button
$btnCreate.Text = "Criar Aplicacao no SCCM"
$btnCreate.Location = New-Object System.Drawing.Point(470, 20)
$btnCreate.Size = New-Object System.Drawing.Size(210, 30)
$btnCreate.BackColor = [System.Drawing.Color]::LightGreen
$grpTest.Controls.Add($btnCreate)

# --- Log ---
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(10, 650)
$txtLog.Size = New-Object System.Drawing.Size(690, 160)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$form.Controls.Add($txtLog)

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    $txtLog.AppendText("[$timestamp] $Message`r`n")
}

# ----------------------------------------------------------------------------
# EVENTOS
# ----------------------------------------------------------------------------

$btnConnect.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtServer.Text) -or [string]::IsNullOrWhiteSpace($txtSiteCode.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Informe o Site Server e o Site Code.", "Aviso") | Out-Null
        return
    }
    Write-Log "Conectando a $($txtServer.Text) ($($txtSiteCode.Text))..."
    $result = Connect-ToSCCM -SiteServer $txtServer.Text -SiteCode $txtSiteCode.Text
    if ($result.Sucesso) {
        $script:SiteServer = $txtServer.Text.Trim()
        $script:SiteCode   = $txtSiteCode.Text.Trim()
        $lblConnStatus.Text = $result.Mensagem
        $lblConnStatus.ForeColor = 'Green'
    } else {
        $lblConnStatus.Text = "Falha: $($result.Mensagem)"
        $lblConnStatus.ForeColor = 'Red'
    }
    Write-Log $result.Mensagem
})

$btnPasteFolder.Add_Click({
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $textoOriginal = [System.Windows.Forms.Clipboard]::GetText()
            $textoLimpo = Get-CleanPath -Path $textoOriginal
            $txtSourceFolder.Text = $textoLimpo
            if ($textoOriginal.Trim() -ne $textoLimpo) {
                Write-Log "Caminho colado foi limpo automaticamente (aspas/espacos removidos)."
            }
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("A area de transferencia nao contem texto.", "Aviso") | Out-Null
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Nao foi possivel ler a area de transferencia. Isso costuma acontecer quando o script esta rodando como Administrador " +
            "e o texto foi copiado por um programa sem elevacao (bloqueio de UIPI do Windows).`n`n" +
            "Solucao: rode o script SEM 'Executar como Administrador' (a conexao ao SCCM nao exige elevacao), " +
            "ou digite o caminho manualmente no campo.",
            "Erro ao colar",
            'OK', 'Warning'
        ) | Out-Null
    }
})

$btnBrowse.Add_Click({
    # FolderBrowserDialog classico nao permite digitar/colar caminhos UNC (\\servidor\pasta).
    # Truque: usar OpenFileDialog (que tem barra de endereco completa e aceita UNC) para
    # navegar/digitar ate a pasta desejada e depois pegar so o diretorio.
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Navegue ate a pasta de origem (ou cole/digite o caminho UNC na barra 'Nome do arquivo') e clique Abrir"
    $dlg.CheckFileExists = $false
    $dlg.CheckPathExists = $true
    $dlg.ValidateNames = $false
    $dlg.Multiselect = $false
    $dlg.FileName = "Selecione esta pasta"
    $dlg.Filter = "Pastas|*.pasta"

    if ($dlg.ShowDialog() -eq 'OK') {
        $pasta = Split-Path $dlg.FileName -Parent
        $txtSourceFolder.Text = $pasta
    }
})

function Complete-FolderScan {
    <#
        Aplica o resultado de um acesso bem-sucedido a pasta de origem:
        guarda os caminhos, escaneia install/uninstall e atualiza a GUI.
    #>
    param(
        [Parameter(Mandatory)][string]$CaminhoOriginal,
        [Parameter(Mandatory)][PSCustomObject]$Acesso
    )

    $script:OriginalSourcePath  = $CaminhoOriginal
    $script:EffectiveSourcePath = $Acesso.CaminhoEfetivo
    Write-Log $Acesso.Mensagem

    $script:InstallInfo   = Get-InstallCommandLine -FolderPath $script:EffectiveSourcePath -Action 'install'
    $script:UninstallInfo = Get-InstallCommandLine -FolderPath $script:EffectiveSourcePath -Action 'uninstall'

    $installStatus   = if ($script:InstallInfo.Encontrado)   { "$($script:InstallInfo.Tipo) ($($script:InstallInfo.Arquivo))" }   else { "NAO ENCONTRADO" }
    $uninstallStatus = if ($script:UninstallInfo.Encontrado) { "$($script:UninstallInfo.Tipo) ($($script:UninstallInfo.Arquivo))" } else { "NAO ENCONTRADO" }
    $lblScanResult.Text = "Instalacao: $installStatus | Desinstalacao: $uninstallStatus"

    if ($script:InstallInfo.Encontrado)   { $txtInstallCmd.Text   = $script:InstallInfo.Comando }   else { $txtInstallCmd.Text = "" }
    if ($script:UninstallInfo.Encontrado) { $txtUninstallCmd.Text = $script:UninstallInfo.Comando } else { $txtUninstallCmd.Text = "" }

    if (-not $script:InstallInfo.Encontrado -or -not $script:UninstallInfo.Encontrado) {
        Write-Log "ATENCAO: nao foram encontrados install.ps1/.bat e/ou uninstall.ps1/.bat na pasta."
    } else {
        Write-Log "Scripts encontrados. Install: $($script:InstallInfo.Comando) | Uninstall: $($script:UninstallInfo.Comando)"
    }

    if ([string]::IsNullOrWhiteSpace($txtDetectPattern.Text) -and -not [string]::IsNullOrWhiteSpace($txtAppName.Text)) {
        $txtDetectPattern.Text = $txtAppName.Text
    }
}

$btnUseInteractiveSession.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtSourceFolder.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Informe a pasta de origem primeiro.", "Aviso") | Out-Null
        return
    }

    $caminhoOriginal = $txtSourceFolder.Text
    $caminhoLimpo    = Get-CleanPath -Path $caminhoOriginal
    if ($caminhoOriginal -ne $caminhoLimpo) {
        $txtSourceFolder.Text = $caminhoLimpo
        Write-Log "Caminho normalizado antes de validar: '$caminhoLimpo'"
    }

    Write-Log "Copiando pasta de origem via sessao interativa logada (sem senha)... isso pode levar alguns segundos."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $acesso = Copy-SourceViaInteractiveSession -SourcePath $caminhoLimpo
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }

    if (-not $acesso.Sucesso) {
        Write-Log "Falha: $($acesso.Mensagem)"
        [System.Windows.Forms.MessageBox]::Show(
            "Nao foi possivel copiar a pasta usando a sessao interativa logada.`n`n" +
            "Detalhe: $($acesso.Mensagem)`n`n" +
            "Alternativas: use o botao 'Ou informar credencial...' se voce tiver um usuario " +
            "e senha (mesmo que seja o seu proprio login do Windows) com acesso a essa pasta.",
            "Falha ao copiar via sessao interativa",
            'OK', 'Warning'
        ) | Out-Null
        return
    }

    $lblSourceCredStatus.Text = "Acesso a pasta: copiada via sessao interativa logada (sem senha)."
    $lblSourceCredStatus.ForeColor = 'Green'
    Complete-FolderScan -CaminhoOriginal $caminhoLimpo -Acesso $acesso
})

$btnSourceCred.Add_Click({
    $cred = Get-Credential -Message "Credenciais com acesso de LEITURA a pasta de origem (ex: sua conta pessoal, se a conta que roda este script - ex: conta de servico do SCCM - nao tiver acesso ao share)"
    if (-not $cred) { return }
    $script:SourceCredential = $cred
    $lblSourceCredStatus.Text = "Acesso a pasta: usando credencial informada ($($cred.UserName))."
    $lblSourceCredStatus.ForeColor = 'Green'
    Write-Log "Credencial alternativa definida para acesso a pasta de origem ($($cred.UserName))."
})

$btnClearSourceCred.Add_Click({
    $script:SourceCredential = $null
    if (Get-PSDrive -Name 'SCCMSRC' -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name 'SCCMSRC' -Force -ErrorAction SilentlyContinue
    }
    $lblSourceCredStatus.Text = "Acesso a pasta: usando a conta atual do script."
    $lblSourceCredStatus.ForeColor = 'Gray'
    Write-Log "Credencial alternativa removida. Voltando a usar a conta atual do script."
})

$btnScan.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtSourceFolder.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Informe a pasta de origem.", "Aviso") | Out-Null
        return
    }

    # Sempre normaliza o texto do campo antes de validar (remove aspas/espacos
    # que podem ter vindo de copia da barra de enderecos do Explorer).
    $caminhoOriginal = $txtSourceFolder.Text
    $caminhoLimpo    = Get-CleanPath -Path $caminhoOriginal
    if ($caminhoOriginal -ne $caminhoLimpo) {
        $txtSourceFolder.Text = $caminhoLimpo
        Write-Log "Caminho normalizado antes de validar: '$caminhoLimpo'"
    }

    if ($script:SourceCredential) {
        Write-Log "Testando acesso a pasta com a credencial alternativa ($($script:SourceCredential.UserName))..."
    } else {
        Write-Log "Testando acesso a pasta com a conta atual do script..."
    }

    $acesso = Resolve-SourceAccess -Path $caminhoLimpo -Credential $script:SourceCredential

    if (-not $acesso.Sucesso) {
        Write-Log "Falha ao acessar a pasta: $($acesso.Mensagem)"
        Write-Log "Caminho testado: [`"$caminhoLimpo`"] (tamanho: $($caminhoLimpo.Length) caracteres)"
        [System.Windows.Forms.MessageBox]::Show(
            "Nao foi possivel acessar este caminho:`n`n$caminhoLimpo`n`n" +
            "Detalhe: $($acesso.Mensagem)`n`n" +
            "Se voce nao tem uma credencial para digitar, use o botao " +
            "'Usar sessao logada (sem senha)' em vez deste.",
            "Nao foi possivel acessar a pasta",
            'OK', 'Warning'
        ) | Out-Null
        return
    }

    Complete-FolderScan -CaminhoOriginal $caminhoLimpo -Acesso $acesso
})

$btnConnectRemote.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtTestMachine.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Informe o nome da maquina teste.", "Aviso") | Out-Null
        return
    }
    if (-not $script:SiteServer -or -not $script:SiteCode) {
        [System.Windows.Forms.MessageBox]::Show("Conecte primeiro ao SCCM no grupo 1.", "Aviso") | Out-Null
        return
    }

    $computer = $txtTestMachine.Text.Trim()
    $btnConnectRemote.Enabled = $false
    $lblRemoteStatus.Text = "Validando $computer pelo SCCM..."
    $lblRemoteStatus.ForeColor = 'DarkOrange'
    [System.Windows.Forms.Application]::DoEvents()

    Write-Log "Validando maquina teste $computer via SCCM Run Script (sem WinRM/sem credencial da estacao)..."
    $result = Connect-RemoteTestMachine -ComputerName $computer

    if ($result.Sucesso) {
        $script:RemoteTestConnected = $true
        $script:RemoteTestComputer  = $computer
        $lblRemoteStatus.Text = "Conectado via SCCM: $computer - execucao remota como SYSTEM."
        $lblRemoteStatus.ForeColor = 'Green'
    }
    else {
        $script:RemoteTestConnected = $false
        $script:RemoteTestComputer  = $null
        $lblRemoteStatus.Text = "Falha via SCCM: $($result.Mensagem)"
        $lblRemoteStatus.ForeColor = 'Red'

        if ($result.Mensagem -match 'APROV') {
            [System.Windows.Forms.MessageBox]::Show(
                $result.Mensagem,
                "Aprovacao unica necessaria",
                'OK', 'Information'
            ) | Out-Null
        }
    }

    Write-Log $result.Mensagem
    $btnConnectRemote.Enabled = $true
})

$btnDisconnectRemote.Add_Click({
    $script:RemoteTestConnected = $false
    $script:RemoteTestComputer  = $null
    $lblRemoteStatus.Text = "Sem maquina teste conectada pelo SCCM (testes rodarao localmente)."
    $lblRemoteStatus.ForeColor = 'Gray'
    Write-Log "Maquina teste desconectada da sessao logica do App Creator. Nenhuma PSSession/WinRM foi usada."
})

$btnTestInstall.Add_Click({
    if (-not $script:InstallInfo -or -not $script:InstallInfo.Encontrado) {
        [System.Windows.Forms.MessageBox]::Show("Escaneie a pasta primeiro.", "Aviso") | Out-Null
        return
    }
    try {
        if ($script:RemoteTestConnected -and $script:RemoteTestComputer) {
            Write-Log "Executando instalacao de teste em $($script:RemoteTestComputer) via SCCM como SYSTEM..."
            Write-Log "A origem usada remotamente sera: $($script:OriginalSourcePath)"
            $output = Invoke-RemoteScriptAction -ComputerName $script:RemoteTestComputer -SourceFolder $script:OriginalSourcePath -ScriptInfo $script:InstallInfo
            Write-Log "  [SCCM/SYSTEM] $output"
        }
        else {
            Write-Log "Executando instalacao de teste LOCALMENTE em: $($script:EffectiveSourcePath)"
            Push-Location $script:EffectiveSourcePath
            if ($script:InstallInfo.Tipo -eq 'PowerShell') {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\$($script:InstallInfo.Arquivo)"
            } else {
                & cmd.exe /c ".\$($script:InstallInfo.Arquivo)"
            }
            Pop-Location
        }
        Write-Log "Instalacao de teste finalizada."
    }
    catch { Write-Log "Erro na instalacao de teste: $($_.Exception.Message)" }
})

$btnTestUninstall.Add_Click({
    if (-not $script:UninstallInfo -or -not $script:UninstallInfo.Encontrado) {
        [System.Windows.Forms.MessageBox]::Show("Escaneie a pasta primeiro.", "Aviso") | Out-Null
        return
    }
    try {
        if ($script:RemoteTestConnected -and $script:RemoteTestComputer) {
            Write-Log "Executando desinstalacao de teste em $($script:RemoteTestComputer) via SCCM como SYSTEM..."
            $output = Invoke-RemoteScriptAction -ComputerName $script:RemoteTestComputer -SourceFolder $script:OriginalSourcePath -ScriptInfo $script:UninstallInfo
            Write-Log "  [SCCM/SYSTEM] $output"
        }
        else {
            Write-Log "Executando desinstalacao de teste LOCALMENTE em: $($script:EffectiveSourcePath)"
            Push-Location $script:EffectiveSourcePath
            if ($script:UninstallInfo.Tipo -eq 'PowerShell') {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\$($script:UninstallInfo.Arquivo)"
            } else {
                & cmd.exe /c ".\$($script:UninstallInfo.Arquivo)"
            }
            Pop-Location
        }
        Write-Log "Desinstalacao de teste finalizada."
    }
    catch { Write-Log "Erro na desinstalacao de teste: $($_.Exception.Message)" }
})

$btnTestDetection.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtDetectPattern.Text) -or [string]::IsNullOrWhiteSpace($txtVersion.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Preencha o padrao do DisplayName e a Versao.", "Aviso") | Out-Null
        return
    }

    $script:DetectionText = New-DetectionScriptText -DisplayNamePattern $txtDetectPattern.Text -MinVersion $txtVersion.Text
    try {
        if ($script:RemoteTestConnected -and $script:RemoteTestComputer) {
            Write-Log "Executando script de deteccao em $($script:RemoteTestComputer) via SCCM como SYSTEM..."
            $raw = Invoke-RemoteDetection -ComputerName $script:RemoteTestComputer -DetectionScriptText $script:DetectionText
            $resultado = $raw
            try {
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                Write-Log "Contexto remoto: $($obj.Identity)"
                $resultado = $obj.Result
            } catch {}
        }
        else {
            Write-Log "Executando script de deteccao LOCALMENTE..."
            $resultado = Invoke-Expression $script:DetectionText
        }

        if (($resultado | Out-String).Trim() -eq 'Instalado') {
            Write-Log "RESULTADO: Instalado (deteccao OK)"
        }
        else {
            Write-Log "RESULTADO: Nao detectado. Retorno: $(($resultado | Out-String).Trim())"
        }
    }
    catch { Write-Log "Erro ao rodar deteccao: $($_.Exception.Message)" }
})

$btnCreate.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtAppName.Text) -or [string]::IsNullOrWhiteSpace($txtVersion.Text) -or
        [string]::IsNullOrWhiteSpace($txtSourceFolder.Text) -or [string]::IsNullOrWhiteSpace($txtDetectPattern.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Preencha Nome, Versao, Pasta de Origem e o padrao de deteccao.", "Aviso") | Out-Null
        return
    }
    if (-not $script:InstallInfo -or -not $script:InstallInfo.Encontrado -or
        -not $script:UninstallInfo -or -not $script:UninstallInfo.Encontrado -or
        -not $script:OriginalSourcePath) {
        [System.Windows.Forms.MessageBox]::Show("Escaneie a pasta (botao 'Escanear Pasta') e confirme que install/uninstall foram encontrados.", "Aviso") | Out-Null
        return
    }

    $script:DetectionText = New-DetectionScriptText -DisplayNamePattern $txtDetectPattern.Text -MinVersion $txtVersion.Text

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Confirma a criacao da aplicacao '$($txtAppName.Text)' no SCCM?`n`nContent Location (UNC real usado pelo SCCM):`n$($script:OriginalSourcePath)",
        "Confirmar",
        [System.Windows.Forms.MessageBoxButtons]::YesNo
    )
    if ($confirm -ne 'Yes') { return }

    Write-Log "Criando aplicacao '$($txtAppName.Text)' no SCCM (ContentLocation: $($script:OriginalSourcePath))..."
    $result = New-SCCMScriptApplication `
        -AppName $txtAppName.Text `
        -Publisher $txtPublisher.Text `
        -Version $txtVersion.Text `
        -SourceFolder $script:OriginalSourcePath `
        -InstallCommand $script:InstallInfo.Comando `
        -UninstallCommand $script:UninstallInfo.Comando `
        -DetectionScript $script:DetectionText

    if ($result.Sucesso) {
        Write-Log $result.Mensagem
        [System.Windows.Forms.MessageBox]::Show($result.Mensagem, "Sucesso") | Out-Null
    } else {
        Write-Log "ERRO: $($result.Mensagem)"
        [System.Windows.Forms.MessageBox]::Show($result.Mensagem, "Erro", 'OK', 'Error') | Out-Null
    }
})

$form.Add_FormClosing({
    if (Get-PSDrive -Name 'SCCMSRC' -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name 'SCCMSRC' -Force -ErrorAction SilentlyContinue
    }
})

Write-Log "Ferramenta iniciada. Conecte ao SCCM e preencha os dados da aplicacao."
[void]$form.ShowDialog()
