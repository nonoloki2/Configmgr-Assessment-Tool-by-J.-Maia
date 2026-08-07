#requires -version 5.1
<#
.SYNOPSIS
    Localiza a linha/comando de desinstalação de produtos Bentley (MicroStation e afins),
    mesmo quando não aparece no caminho padrão do registro nem no Programas e Recursos.

.DESCRIÇÃO
    Diferente de uma varredura simples do Uninstall\* em HKLM, este script:
      1. Varre HKLM (64 e 32 bits) e HKCU do usuário atual.
      2. Varre o hive HKEY_USERS de TODOS os perfis do Windows na máquina — inclusive
         perfis de outros usuários que não estão logados no momento (carregando o
         NTUSER.DAT temporariamente). Isso é essencial porque, se o MicroStation foi
         instalado enquanto outro usuário estava logado (ou "só para o usuário atual"),
         o registro de desinstalação pode existir apenas na colmeia HKCU daquele usuário
         — e nunca vai aparecer quando você olha pelo seu próprio usuário.
      3. Consulta as chaves nativas da Bentley em HKLM\SOFTWARE\Bentley (e WOW6432Node),
         onde o produto pode estar catalogado mesmo sem uma entrada ARP (Add/Remove
         Programs) — comum quando a instalação ficou incompleta ou corrompida.
      4. Faz uma busca no sistema de arquivos pelo executável real (ustation.exe) e por
         pastas "Bentley"/"MicroStation", cobrindo local padrão, ProgramData\Package Cache
         e, opcionalmente, o disco inteiro.
      5. Gera uma recomendação de comando de desinstalação silenciosa, seguindo a sintaxe
         oficial documentada pela Bentley para produtos CONNECT Edition:
             "<Setup_MicroStationXXXX.exe>" -Uninstall -Quiet
         ou, quando há ProductCode do Windows Installer:
             msiexec.exe /x {GUID} /qn /norestart

.USO
    # Varredura padrão (rápida, sem varrer o disco inteiro)
    .\Find-MicroStation-Uninstall.ps1

    # Trocar o termo de busca
    .\Find-MicroStation-Uninstall.ps1 -Term "Bentley"

    # Buscar também no disco inteiro (mais lento, útil se nada aparecer)
    .\Find-MicroStation-Uninstall.ps1 -DeepFileSearch

    # Não perguntar sobre elevação (assume que já está admin ou não quer varrer outros perfis)
    .\Find-MicroStation-Uninstall.ps1 -SkipElevationPrompt

.OBSERVAÇÃO
    Rodar como Administrador é o que permite varrer os perfis de OUTROS usuários e o disco
    inteiro. Sem elevação, o script ainda funciona, só que com escopo menor (mostra um aviso).
#>

[CmdletBinding()]
param(
    [string]$Term = 'MicroStation',
    [switch]$DeepFileSearch,
    [switch]$SkipElevationPrompt
)

$ErrorActionPreference = 'Continue'
$reportLines = New-Object System.Collections.Generic.List[string]
function Log {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    $reportLines.Add($Text)
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$isAdmin = Test-IsAdmin
if (-not $isAdmin -and -not $SkipElevationPrompt) {
    Write-Host ""
    Write-Host "Este script NÃO está rodando como Administrador." -ForegroundColor Yellow
    Write-Host "Sem elevação, ele não consegue ler o registro de OUTROS usuários nem varrer" -ForegroundColor Yellow
    Write-Host "todo o disco. Isso é frequentemente a causa de 'não achei nada'." -ForegroundColor Yellow
    $resp = Read-Host "Reabrir este script elevado como Administrador agora? (S/N)"
    if ($resp -match '^[sS]') {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoExit','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"",
            '-Term', "`"$Term`"",
            $(if ($DeepFileSearch) { '-DeepFileSearch' })
        )
        exit
    }
}

Log "==================================================================" 'Cyan'
Log " Busca profunda de desinstalação Bentley/MicroStation" 'Cyan'
Log " Termo: '$Term'  |  Admin: $isAdmin  |  Deep file search: $($DeepFileSearch.IsPresent)" 'Cyan'
Log "==================================================================" 'Cyan'

$found = New-Object System.Collections.Generic.List[object]

# ---------------------------------------------------------------------------
# 1) Registro padrão ARP (HKLM 64/32 + HKCU do usuário atual)
# ---------------------------------------------------------------------------
Log "`n[1/4] Varrendo Uninstall\* padrão (HKLM 64/32 bits, HKCU atual)..." 'White'
$arpPaths = @(
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
foreach ($path in $arpPaths) {
    try {
        $items = @(Get-ItemProperty -Path $path -ErrorAction Stop)
        foreach ($i in $items) {
            if ([string]::IsNullOrWhiteSpace([string]$i.DisplayName)) { continue }
            if ($i.DisplayName -notmatch [regex]::Escape($Term) -and $i.Publisher -notmatch '(?i)Bentley') { continue }
            $found.Add([pscustomobject]@{
                Source = "Registro ARP: $path"
                Name   = $i.DisplayName
                Info   = "UninstallString: $($i.UninstallString)  |  QuietUninstallString: $($i.QuietUninstallString)"
            })
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# 2) Registro ARP de TODOS os perfis de usuário (logados ou não)
# ---------------------------------------------------------------------------
Log "[2/4] Varrendo Uninstall\* em TODOS os perfis de usuário da máquina..." 'White'
if (-not $isAdmin) {
    Log "      (pulado parcialmente — sem admin não dá pra carregar hives de outros usuários)" 'DarkYellow'
}

$profileListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$profiles = @(Get-ChildItem $profileListKey -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($p.ProfileImagePath -and (Test-Path "$($p.ProfileImagePath)\NTUSER.DAT")) {
        [pscustomobject]@{ SID = $_.PSChildName; Path = $p.ProfileImagePath }
    }
})

foreach ($prof in $profiles) {
    $hivePath = "Registry::HKEY_USERS\$($prof.SID)"
    $alreadyLoaded = Test-Path $hivePath
    $tempKeyName = $null

    if (-not $alreadyLoaded) {
        if (-not $isAdmin) { continue }
        $tempKeyName = "TempHive_$($prof.SID -replace '[^A-Za-z0-9]','')"
        $loadResult = & reg.exe load "HKU\$tempKeyName" "$($prof.Path)\NTUSER.DAT" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Log "      Não foi possível carregar hive de $($prof.Path) (provavelmente em uso): $loadResult" 'DarkYellow'
            continue
        }
        $scanKey = "Registry::HKEY_USERS\$tempKeyName"
    } else {
        $scanKey = $hivePath
    }

    $uninstallKey = "$scanKey\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    try {
        $items = @(Get-ItemProperty -Path $uninstallKey -ErrorAction Stop)
        foreach ($i in $items) {
            if ([string]::IsNullOrWhiteSpace([string]$i.DisplayName)) { continue }
            if ($i.DisplayName -notmatch [regex]::Escape($Term) -and $i.Publisher -notmatch '(?i)Bentley') { continue }
            $found.Add([pscustomobject]@{
                Source = "Perfil: $($prof.Path)"
                Name   = $i.DisplayName
                Info   = "UninstallString: $($i.UninstallString)  |  QuietUninstallString: $($i.QuietUninstallString)"
            })
        }
    } catch { }

    if ($tempKeyName) {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg.exe unload "HKU\$tempKeyName" 2>&1 | Out-Null
    }
}

# ---------------------------------------------------------------------------
# 3) Chaves nativas da Bentley (fora do padrão ARP)
# ---------------------------------------------------------------------------
Log "[3/4] Verificando chaves nativas da Bentley (HKLM\SOFTWARE\Bentley)..." 'White'
$bentleyRoots = @(
    'HKLM:\SOFTWARE\Bentley',
    'HKLM:\SOFTWARE\WOW6432Node\Bentley'
)
foreach ($root in $bentleyRoots) {
    if (Test-Path $root) {
        Get-ChildItem $root -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.PSChildName -match [regex]::Escape($Term) -or $_.Name -match '(?i)MicroStation') {
                $found.Add([pscustomobject]@{
                    Source = "Chave nativa Bentley"
                    Name   = $_.PSChildName
                    Info   = "Caminho: $($_.Name)"
                })
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 4) Sistema de arquivos: ustation.exe, Package Cache, pastas Bentley
# ---------------------------------------------------------------------------
Log "[4/4] Procurando o executável real (ustation.exe) e pastas Bentley em disco..." 'White'

$quickRoots = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    "$env:ProgramData\Bentley",
    "$env:ProgramData\Package Cache",
    "$env:LOCALAPPDATA\Programs"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

foreach ($root in $quickRoots) {
    Get-ChildItem -Path $root -Recurse -File -Include 'ustation.exe','Setup_MicroStation*.exe' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $found.Add([pscustomobject]@{
                Source = "Disco (busca rápida)"
                Name   = $_.Name
                Info   = "Caminho: $($_.FullName)"
            })
        }
    Get-ChildItem -Path $root -Directory -Filter '*Bentley*' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $found.Add([pscustomobject]@{
                Source = "Disco (pasta)"
                Name   = $_.Name
                Info   = "Caminho: $($_.FullName)"
            })
        }
}

if ($DeepFileSearch) {
    Log "      Varredura completa do disco ativada — isso pode demorar vários minutos." 'DarkYellow'
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null }
    foreach ($d in $drives) {
        $rootPath = "$($d.Name):\"
        Get-ChildItem -Path $rootPath -Recurse -File -Include 'ustation.exe' -ErrorAction SilentlyContinue -Force |
            ForEach-Object {
                $found.Add([pscustomobject]@{
                    Source = "Disco (varredura completa $rootPath)"
                    Name   = $_.Name
                    Info   = "Caminho: $($_.FullName)"
                })
            }
    }
}

# ---------------------------------------------------------------------------
# Resultado final
# ---------------------------------------------------------------------------
Log "`n==================================================================" 'Cyan'
if ($found.Count -eq 0) {
    Log "NENHUM vestígio de '$Term' encontrado no registro (nenhum perfil), em" 'Red'
    Log "chaves nativas da Bentley, nem no sistema de arquivos (busca rápida)." 'Red'
    Log ""
    Log "Isso indica fortemente que o MicroStation 2026 NÃO está instalado nesta" 'Yellow'
    Log "máquina — ou foi instalado num disco/pasta fora do padrão que a busca" 'Yellow'
    Log "rápida não cobre. Sugestões:" 'Yellow'
    Log "  - Rode de novo com -DeepFileSearch para varrer o disco inteiro." 'Yellow'
    Log "  - Confirme com quem instalou/administra a licença se a instalação" 'Yellow'
    Log "    foi realmente concluída nesta máquina (vs. só baixado o instalador)." 'Yellow'
    Log "  - Verifique se não foi instalado numa VM, container, ou perfil de" 'Yellow'
    Log "    domínio que não sincronizou para este computador." 'Yellow'
} else {
    Log "$($found.Count) resultado(s) relevante(s) encontrado(s):" 'Green'
    Log ""
    $n = 0
    foreach ($f in $found) {
        $n++
        Log "[$n] $($f.Name)" 'Green'
        Log "     Origem : $($f.Source)"
        Log "     $($f.Info)"
        Log ""
    }
    Log "Comando de desinstalação silenciosa oficial da Bentley (CONNECT Edition):" 'Cyan'
    Log '  "<caminho_do_Setup_MicroStationXXXX.exe>" -Uninstall -Quiet' 'Cyan'
    Log "Se em vez disso você tiver um ProductCode (GUID) do Windows Installer:" 'Cyan'
    Log "  msiexec.exe /x {GUID} /qn /norestart" 'Cyan'
}
Log "==================================================================" 'Cyan'

$reportPath = Join-Path $env:USERPROFILE "Desktop\MicroStation_Uninstall_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
try {
    $reportLines -join "`r`n" | Out-File -FilePath $reportPath -Encoding UTF8
    Write-Host "`nRelatório salvo em: $reportPath" -ForegroundColor Magenta
} catch { }
