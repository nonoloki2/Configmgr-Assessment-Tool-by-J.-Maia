#Requires -Version 5.1
<#
================================================================================
 ConfigMgr Infrastructure Health Assessment Tool
 Autor: (personalize aqui)
 Descricao:
   Ferramenta grafica (WinForms) que coleta a saude da infraestrutura do
   Microsoft Configuration Manager (SCCM/MECM) via WMI/CIM (SMS Provider) e
   remoting nos servidores de sistema de site, e gera um relatorio HTML
   autocontido (sem dependencia de internet/CDN), com cards por servidor,
   abas por area (Overview, Operating System, Storage, Services,
   Distribution Point/MP/SUP) e destaque visual (vermelho) em qualquer
   aba/secao que contenha um problema.

 Pre-requisitos:
   - Executar em uma estacao com acesso ao WMI do Site Server (SMS Provider).
   - Conta com direitos de leitura no ConfigMgr (Read-Only Analyst basta para
     leitura) e permissao de admin local / WinRM nos servidores remotos para
     coleta de SO, disco, servicos e certificados IIS.
   - WinRM habilitado nos servidores de sistema de site (para CPU/RAM,
     servicos, certificados IIS). Sem WinRM, essas checagens ficam "Sem dados".
   - Modulo ActiveDirectory (RSAT) e opcional, usado para o cruzamento de
     "dispositivos sem cliente que logaram no dominio nos ultimos 30 dias".
   - Modulo UpdateServices (RSAT) e opcional, usado para detalhar a saude do
     WSUS (ultima sincronizacao). Sem o modulo, a ferramenta ainda reporta o
     estado do servico WsusService e espaco em disco do WSUS.
================================================================================
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# =====================================================================================
# REGIAO: CONFIGURACAO GLOBAL / LIMIARES
# =====================================================================================
# IMPORTANTE: a configuracao fica dentro de uma funcao (em vez de atribuicoes soltas
# no topo do arquivo) para que possa ser reexecutada de forma identica dentro do
# runspace de background usado pela GUI (evita problemas de escopo de variavel entre
# runspaces distintos).
function Initialize-ScriptConfig {
    $global:AppName    = "ConfigMgr Infrastructure Health Assessment"
    $global:AppVersion = "1.0.0"

    $global:Thresholds = [ordered]@{
        DiskFreePctCritical   = 10
        DiskFreePctWarning    = 20
        MemPctCritical        = 90
        MemPctWarning         = 80
        CpuPctCritical        = 90
        CpuPctWarning         = 75
        PatchDaysWarning      = 45
        PatchDaysCritical     = 60
        CertExpiryCriticalDays= 15
        CertExpiryWarningDays = 60
        InactiveClientDays    = 30
        ADLogonDays           = 30
        UptimeWarningDays     = 60
        UptimeCriticalDays    = 90
    }

    $global:RolesOfInterest = @(
        "SMS Distribution Point",
        "SMS Management Point",
        "SMS Software Update Point",
        "SMS Site System",
        "SMS Site Server",
        "SMS SQL Server",
        "SMS Fallback Status Point",
        "SMS Reporting Point",
        "SMS Endpoint Protection Point",
        "SMS State Migration Point"
    )

    $global:RoleShortName = @{
        "SMS Distribution Point"        = "DP"
        "SMS Management Point"          = "MP"
        "SMS Software Update Point"     = "SUP"
        "SMS Site System"               = "Site System"
        "SMS Site Server"               = "Site Server"
        "SMS SQL Server"                = "SQL"
        "SMS Fallback Status Point"     = "FSP"
        "SMS Reporting Point"           = "Reporting"
        "SMS Endpoint Protection Point" = "EP"
        "SMS State Migration Point"     = "SMP"
    }

    # Ordem de severidade (maior indice = mais grave)
    $global:StatusRank = @{
        "NotApplicable" = 0
        "Info"          = 1
        "Healthy"       = 2
        "Warning"       = 3
        "Critical"      = 4
    }
}
Initialize-ScriptConfig

# =====================================================================================
# REGIAO: HELPERS DE STATUS
# =====================================================================================

function New-Finding {
    param(
        [string]$Check,
        [ValidateSet("Healthy","Warning","Critical","Info","NotApplicable")]
        [string]$Status,
        [string]$Value = "",
        [string]$FindingText = "",
        [string]$Evidence = "",
        [string]$Recommendation = ""
    )
    [PSCustomObject]@{
        Check          = $Check
        Status         = $Status
        Value          = $Value
        Finding        = $FindingText
        Evidence       = $Evidence
        Recommendation = $Recommendation
    }
}

function Get-WorstStatus {
    param([string[]]$Statuses)
    if (-not $Statuses -or $Statuses.Count -eq 0) { return "NotApplicable" }
    $worst = "NotApplicable"
    foreach ($s in $Statuses) {
        if ($null -eq $s -or $s -eq "") { continue }
        if ($global:StatusRank[$s] -gt $global:StatusRank[$worst]) { $worst = $s }
    }
    return $worst
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message
    if ($global:SyncHash) {
        [void]$global:SyncHash.LogQueue.Add($line)
    } else {
        Write-Host $line
    }
}

# =====================================================================================
# REGIAO: COLETA - SMS PROVIDER (ROOT\SMS\SITE_<CODE>)
# =====================================================================================

function Invoke-SmsQuery {
    # Tenta CIM (WSMan) e, se falhar (ex.: WinRM nao habilitado no Site Server),
    # cai para WMI classico via DCOM (Get-WmiObject), que costuma estar sempre
    # disponivel em ambientes ConfigMgr por ser usado pelo proprio console.
    param([string]$SiteServer, [string]$Namespace, [string]$ClassName, [string]$Filter)
    try {
        $params = @{ ComputerName=$SiteServer; Namespace=$Namespace; ClassName=$ClassName; ErrorAction='Stop' }
        if ($Filter) { $params.Filter = $Filter }
        return Get-CimInstance @params
    } catch {
        try {
            $params = @{ ComputerName=$SiteServer; Namespace=$Namespace; Class=$ClassName; ErrorAction='Stop' }
            if ($Filter) { $params.Filter = $Filter }
            return Get-WmiObject @params
        } catch {
            throw $_
        }
    }
}

function Get-SiteSystemRoles {
    param([string]$SiteCode, [string]$SiteServer)
    try {
        $ns = "root\sms\site_$SiteCode"
        $roles = Invoke-SmsQuery -SiteServer $SiteServer -Namespace $ns -ClassName SMS_SystemResourceList |
            Where-Object { $global:RolesOfInterest -contains $_.RoleName } |
            Select-Object ServerName, RoleName, SslState, NALPath
        return $roles
    } catch {
        Write-Log "Failed to query SMS_SystemResourceList: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

function Get-ContentDistributionErrors {
    param([string]$SiteCode, [string]$SiteServer)
    # State: 0=Installed / conjunto de estados de falha conhecidos: 3=Install Failed, 7=Removal Failed
    # Tambem tratamos MessageState >= 3 (Warning/Error conforme SDK) como achado.
    try {
        $ns = "root\sms\site_$SiteCode"
        $rows = Invoke-SmsQuery -SiteServer $SiteServer -Namespace $ns -ClassName SMS_PackageStatusDistPointsSummarizer
        $errorStates = @{ 3 = "Install Failed"; 7 = "Removal Failed" }
        $results = foreach ($r in $rows) {
            if ($errorStates.ContainsKey([int]$r.State)) {
                $pkgName = $r.PackageID
                try {
                    $pkg = Invoke-SmsQuery -SiteServer $SiteServer -Namespace $ns -ClassName SMS_Package -Filter "PackageID='$($r.PackageID)'"
                    if ($pkg) { $pkgName = "$($pkg.Name) ($($r.PackageID))" }
                } catch {}
                [PSCustomObject]@{
                    PackageID  = $r.PackageID
                    PackageName= $pkgName
                    Server     = ($r.ServerNALPath -replace '.*\\\\','' -replace '\\.*','')
                    State      = $errorStates[[int]$r.State]
                    LastUpdate = $r.LastUpdateDate
                }
            }
        }
        return $results
    } catch {
        Write-Log "Failed to query content distribution status: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

function Get-BoundariesWithoutGroup {
    param([string]$SiteCode, [string]$SiteServer)
    try {
        $ns = "root\sms\site_$SiteCode"
        $boundaries = Invoke-SmsQuery -SiteServer $SiteServer -Namespace $ns -ClassName SMS_Boundary
        $members    = Invoke-SmsQuery -SiteServer $SiteServer -Namespace $ns -ClassName SMS_BoundaryGroupMembers
        $memberIds  = $members | Select-Object -ExpandProperty BoundaryID -Unique
        $orphans = $boundaries | Where-Object { $memberIds -notcontains $_.BoundaryID }
        return $orphans | Select-Object BoundaryID, DisplayName, BoundaryType, Value
    } catch {
        Write-Log "Failed to query boundaries: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

function Get-DevicesWithoutClient {
    param([string]$SiteCode, [string]$SiteServer, [int]$DaysBack = 30)
    $result = [PSCustomObject]@{
        Available = $false
        Devices   = @()
        Note      = ""
    }
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        $result.Note = "ActiveDirectory module (RSAT) not available on this machine; check skipped."
        Write-Log $result.Note "WARN"
        return $result
    }
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $ns = "root\sms\site_$SiteCode"
        $cutoff = (Get-Date).AddDays(-$DaysBack)
        $adComputers = Get-ADComputer -Filter { LastLogonTimeStamp -gt $cutoff } -Properties LastLogonTimeStamp |
            Select-Object Name, @{n='LastLogon';e={[DateTime]::FromFileTime($_.LastLogonTimeStamp)}}

        $smsClients = Invoke-SmsQuery -SiteServer $SiteServer -Namespace $ns -ClassName SMS_R_System -Filter "Client=1" |
            Select-Object -ExpandProperty Name

        $smsClientSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($n in $smsClients) { [void]$smsClientSet.Add($n) }

        $missing = $adComputers | Where-Object { -not $smsClientSet.Contains($_.Name) }
        $result.Available = $true
        $result.Devices = $missing | Sort-Object LastLogon -Descending |
            Select-Object Name, @{n='LastLogon';e={$_.LastLogon.ToString("yyyy-MM-dd HH:mm")}}
        return $result
    } catch {
        $result.Note = "Failed to cross-reference AD and SCCM: $($_.Exception.Message)"
        Write-Log $result.Note "ERROR"
        return $result
    }
}

function Get-ClientHealthIssues {
    param([string]$SiteCode, [string]$SiteServer)
    $result = [PSCustomObject]@{
        Inactive          = @()
        ClientCheckFailed = @()
    }
    try {
        $ns = "root\sms\site_$SiteCode"
        $devices = Invoke-SmsQuery -SiteServer $SiteServer -Namespace $ns -ClassName SMS_CombinedDeviceResources |
            Where-Object { $_.IsClient -eq $true }

        $result.Inactive = $devices | Where-Object { $_.ClientActiveStatus -eq 0 } |
            Select-Object Name, @{n='LastActiveTime';e={$_.LastActiveTime}}, ClientStateDescription |
            Sort-Object LastActiveTime

        $result.ClientCheckFailed = $devices | Where-Object { $_.ClientCheckPass -eq $false -or $_.ClientCheckPass -eq 0 } |
            Select-Object Name, ClientStateDescription, LastActiveTime

        return $result
    } catch {
        Write-Log "Failed to query SMS_CombinedDeviceResources: $($_.Exception.Message)" "ERROR"
        return $result
    }
}

# =====================================================================================
# REGIAO: COLETA - REMOTA NOS SERVIDORES (CIM/WinRM)
# =====================================================================================

function New-RemoteCimSession {
    param([string]$ComputerName, [PSCredential]$Credential)
    try {
        $opt = New-CimSessionOption -Protocol Wsman
        if ($Credential) {
            return New-CimSession -ComputerName $ComputerName -Credential $Credential -SessionOption $opt -ErrorAction Stop -OperationTimeoutSec 20
        } else {
            return New-CimSession -ComputerName $ComputerName -SessionOption $opt -ErrorAction Stop -OperationTimeoutSec 20
        }
    } catch {
        return $null
    }
}

function Test-ServerConnectivity {
    param([string]$ComputerName)
    $findings = @()
    # DNS
    try {
        $dns = [System.Net.Dns]::GetHostAddresses($ComputerName) | ForEach-Object { $_.IPAddressToString }
        $findings += New-Finding -Check "DNS Resolve" -Status "Healthy" -Value ($dns -join "; ") -FindingText "DNS resolution succeeded."
    } catch {
        $findings += New-Finding -Check "DNS Resolve" -Status "Critical" -Value "N/A" -FindingText "DNS resolution failed." -Evidence $_.Exception.Message
        return $findings, $false
    }
    # Ping
    try {
        $ping = Test-Connection -ComputerName $ComputerName -Count 3 -ErrorAction Stop
        $avg = [math]::Round(($ping | Measure-Object -Property ResponseTime -Average).Average,0)
        $findings += New-Finding -Check "Ping" -Status "Healthy" -Value "Avg=${avg}ms" -FindingText "Average ping $avg ms."
    } catch {
        $findings += New-Finding -Check "Ping" -Status "Warning" -Value "No response" -FindingText "Host did not respond to ICMP (may be blocked by a firewall)."
    }
    # WinRM
    $winrmOk = $false
    try {
        $null = Test-WSMan -ComputerName $ComputerName -ErrorAction Stop
        $winrmOk = $true
        $findings += New-Finding -Check "WinRM" -Status "Healthy" -Value "Available" -FindingText "WinRM available."
    } catch {
        $findings += New-Finding -Check "WinRM" -Status "Critical" -Value "Unavailable" -FindingText "WinRM unavailable; remote checks (OS, disk, services, RAM/CPU, certificates) will be skipped." -Evidence $_.Exception.Message
    }
    return $findings, $winrmOk
}

function Get-ServerOSAndPerf {
    param([string]$ComputerName, [PSCredential]$Credential)
    $findings = @()
    $cs = New-RemoteCimSession -ComputerName $ComputerName -Credential $Credential
    if (-not $cs) {
        $findings += New-Finding -Check "OS Version" -Status "NotApplicable" -FindingText "No remote session (WinRM unavailable)."
        return $findings
    }
    try {
        $os  = Get-CimInstance -CimSession $cs -ClassName Win32_OperatingSystem
        $cpu = Get-CimInstance -CimSession $cs -ClassName Win32_Processor
        $csi = Get-CimInstance -CimSession $cs -ClassName Win32_ComputerSystem

        # OS Version
        $findings += New-Finding -Check "OS Version" -Status "Info" -Value $os.Caption `
            -FindingText $os.Caption `
            -Evidence "Version=$($os.Version); Build=$($os.BuildNumber); Architecture=$($os.OSArchitecture)"

        # Uptime
        $lastBoot = $os.LastBootUpTime
        $uptimeDays = [math]::Round(((Get-Date) - $lastBoot).TotalDays,1)
        $upStatus = "Healthy"
        if ($uptimeDays -ge $global:Thresholds.UptimeCriticalDays) { $upStatus = "Warning" }
        $findings += New-Finding -Check "Uptime" -Status $upStatus -Value "$uptimeDays days" `
            -FindingText "Last boot: $($lastBoot.ToString('yyyy-MM-dd HH:mm')); Uptime: $uptimeDays days." `
            -Evidence "LastBoot=$($lastBoot.ToString('yyyy-MM-dd HH:mm:ss'))"

        # Memoria
        $totalMemGB = [math]::Round($csi.TotalPhysicalMemory/1GB,1)
        $freeMemGB  = [math]::Round(($os.FreePhysicalMemory*1KB)/1GB,1)
        $usedPct    = [math]::Round((($totalMemGB-$freeMemGB)/$totalMemGB)*100,1)
        $memStatus = "Healthy"
        if ($usedPct -ge $global:Thresholds.MemPctCritical) { $memStatus = "Critical" }
        elseif ($usedPct -ge $global:Thresholds.MemPctWarning) { $memStatus = "Warning" }
        $findings += New-Finding -Check "Memory (RAM)" -Status $memStatus -Value "$usedPct% used ($totalMemGB GB total)" `
            -FindingText "RAM: $freeMemGB GB free of $totalMemGB GB ($usedPct% in use)." `
            -Evidence "Total=${totalMemGB}GB; Free=${freeMemGB}GB; UsedPct=$usedPct%" `
            -Recommendation $(if ($memStatus -eq "Critical") { "Critical memory usage; investigate processes and consider increasing RAM." } else { "" })

        # CPU (media de 2 amostras rapidas)
        $load1 = ($cpu | Measure-Object -Property LoadPercentage -Average).Average
        Start-Sleep -Milliseconds 500
        $cpu2 = Get-CimInstance -CimSession $cs -ClassName Win32_Processor
        $load2 = ($cpu2 | Measure-Object -Property LoadPercentage -Average).Average
        $cpuAvg = [math]::Round((($load1+$load2)/2),1)
        $cpuStatus = "Healthy"
        if ($cpuAvg -ge $global:Thresholds.CpuPctCritical) { $cpuStatus = "Critical" }
        elseif ($cpuAvg -ge $global:Thresholds.CpuPctWarning) { $cpuStatus = "Warning" }
        $findings += New-Finding -Check "CPU Usage" -Status $cpuStatus -Value "$cpuAvg%" `
            -FindingText "Average CPU usage at collection time: $cpuAvg%." `
            -Evidence "Samples=$load1%, $load2%" `
            -Recommendation $(if ($cpuStatus -eq "Critical") { "Critical CPU usage; investigate high-consumption processes." } else { "" })

        # Patch
        try {
            $hotfixes = Get-CimInstance -CimSession $cs -ClassName Win32_QuickFixEngineering -ErrorAction Stop |
                Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending
            if ($hotfixes) {
                $last = $hotfixes | Select-Object -First 1
                $daysSince = [math]::Round(((Get-Date) - [datetime]$last.InstalledOn).TotalDays,1)
                $patchStatus = "Healthy"
                if ($daysSince -ge $global:Thresholds.PatchDaysCritical) { $patchStatus = "Critical" }
                elseif ($daysSince -ge $global:Thresholds.PatchDaysWarning) { $patchStatus = "Warning" }
                $findings += New-Finding -Check "Last Installed Patch" -Status $patchStatus -Value "$($last.HotFixID) ($daysSince days ago)" `
                    -FindingText "Last installed KB: $($last.HotFixID) on $([datetime]$last.InstalledOn | Get-Date -Format 'yyyy-MM-dd')." `
                    -Evidence "DaysSinceLastPatch=$daysSince" `
                    -Recommendation $(if ($patchStatus -ne "Healthy") { "Review the patching cycle / update compliance on this server." } else { "" })
            } else {
                $findings += New-Finding -Check "Last Installed Patch" -Status "Warning" -Value "No data" -FindingText "No KB found via Win32_QuickFixEngineering."
            }
        } catch {
            $findings += New-Finding -Check "Last Installed Patch" -Status "NotApplicable" -FindingText "Failed to query hotfixes." -Evidence $_.Exception.Message
        }
    } catch {
        $findings += New-Finding -Check "OS Version" -Status "Critical" -FindingText "Failed to collect OS/performance data." -Evidence $_.Exception.Message
    } finally {
        Remove-CimSession -CimSession $cs -ErrorAction SilentlyContinue
    }

    # Reinicializacao pendente (checagem via registro, independente da sessao CIM)
    $findings += Get-ServerPendingReboot -ComputerName $ComputerName -Credential $Credential

    return $findings
}

function Get-ServerDiskInfo {
    param([string]$ComputerName, [PSCredential]$Credential)
    $disks = @()
    $cs = New-RemoteCimSession -ComputerName $ComputerName -Credential $Credential
    if (-not $cs) { return $disks }
    try {
        $vols = Get-CimInstance -CimSession $cs -ClassName Win32_LogicalDisk -Filter "DriveType=3"
        foreach ($v in $vols) {
            $totalGB = [math]::Round($v.Size/1GB,2)
            $freeGB  = [math]::Round($v.FreeSpace/1GB,2)
            $usedGB  = [math]::Round($totalGB-$freeGB,2)
            if ($totalGB -gt 0) {
                $freePct = [math]::Round(($freeGB/$totalGB)*100,2)
            } else { $freePct = 0 }
            $status = "Healthy"
            if ($freePct -le $global:Thresholds.DiskFreePctCritical) { $status = "Critical" }
            elseif ($freePct -le $global:Thresholds.DiskFreePctWarning) { $status = "Warning" }
            if ($totalGB -eq 0) { $status = "NotApplicable" }

            $rec = "No action required."
            if ($status -eq "Critical") { $rec = "Disk space critically low; free up space or expand the volume urgently." }
            elseif ($status -eq "Warning") { $rec = "Disk space warning; plan for cleanup/expansion." }

            $disks += [PSCustomObject]@{
                Drive   = $v.DeviceID
                Status  = $status
                TotalGB = $totalGB
                FreeGB  = $freeGB
                UsedGB  = $usedGB
                FreePct = $freePct
                Recommendation = $rec
            }
        }
    } catch {
        Write-Log "Failed to collect disk data from ${ComputerName}: $($_.Exception.Message)" "ERROR"
    } finally {
        Remove-CimSession -CimSession $cs -ErrorAction SilentlyContinue
    }
    return $disks
}

function Get-ServerPendingReboot {
    param([string]$ComputerName, [PSCredential]$Credential)
    try {
        $sb = {
            $motivos = @()
            if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
                $motivos += "Component Based Servicing"
            }
            if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
                $motivos += "Windows Update"
            }
            try {
                $pfro = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
                if ($pfro -and $pfro.PendingFileRenameOperations) { $motivos += "Pending File Rename Operations" }
            } catch {}
            try {
                $ativo   = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
                $pendente= (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
                if ($ativo -and $pendente -and $ativo -ne $pendente) { $motivos += "Renomeacao de computador pendente" }
            } catch {}
            try {
                if (Test-Path "HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client\Reboot Management\RebootData") { $motivos += "ConfigMgr Client" }
            } catch {}
            [PSCustomObject]@{ Pendente = ($motivos.Count -gt 0); Motivos = $motivos }
        }
        $params = @{ ComputerName = $ComputerName; ScriptBlock = $sb; ErrorAction = "Stop" }
        if ($Credential) { $params.Credential = $Credential }
        $r = Invoke-Command @params

        if ($r.Pendente) {
            return New-Finding -Check "Pending Reboot" -Status "Warning" -Value "Yes" `
                -FindingText "Server has a pending reboot. Reason(s): $($r.Motivos -join ', ')." `
                -Recommendation "Schedule a server reboot during a maintenance window as soon as possible."
        } else {
            return New-Finding -Check "Pending Reboot" -Status "Healthy" -Value "No" `
                -FindingText "No pending reboot detected."
        }
    } catch {
        return New-Finding -Check "Pending Reboot" -Status "NotApplicable" `
            -FindingText "Failed to check pending reboot status (requires WinRM)." -Evidence $_.Exception.Message
    }
}

function Get-ServerServiceHealth {
    param([string]$ComputerName, [string[]]$ServiceNames, [PSCredential]$Credential)
    $findings = @()
    $cs = New-RemoteCimSession -ComputerName $ComputerName -Credential $Credential
    if (-not $cs) {
        foreach ($svc in $ServiceNames) {
            $findings += New-Finding -Check "Service: $svc" -Status "NotApplicable" -FindingText "No remote session."
        }
        return $findings
    }
    try {
        foreach ($svcName in $ServiceNames) {
            $svc = Get-CimInstance -CimSession $cs -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
            if (-not $svc) {
                $findings += New-Finding -Check "Service: $svcName" -Status "NotApplicable" -Value "Not installed" -FindingText "Service not found on this server."
                continue
            }
            $status = "Healthy"
            if ($svc.State -ne "Running") { $status = "Critical" }
            elseif ($svc.StartMode -eq "Disabled") { $status = "Warning" }
            $findings += New-Finding -Check "Service: $svcName" -Status $status -Value "$($svc.State) / Start=$($svc.StartMode)" `
                -FindingText "Service $svcName is $($svc.State)." `
                -Recommendation $(if ($status -eq "Critical") { "Service $svcName is stopped; start it and investigate the Event Log." } else { "" })
        }
    } finally {
        Remove-CimSession -CimSession $cs -ErrorAction SilentlyContinue
    }
    return $findings
}

function Get-IISCertHealth {
    param([string]$ComputerName, [PSCredential]$Credential)
    $findings = @()
    try {
        $sb = {
            $out = @()
            try {
                Import-Module WebAdministration -ErrorAction Stop
                $bindings = Get-ChildItem IIS:\SslBindings -ErrorAction SilentlyContinue
                if (-not $bindings) {
                    $out += [PSCustomObject]@{ Binding="(nenhum)"; Thumbprint=$null; NotAfter=$null; Error="Nenhum binding SSL encontrado." }
                }
                foreach ($b in $bindings) {
                    $thumb = $b.Thumbprint
                    $cert = Get-ChildItem "Cert:\LocalMachine\My\$thumb" -ErrorAction SilentlyContinue
                    $out += [PSCustomObject]@{
                        Binding    = "$($b.IPAddress):$($b.Port)"
                        Thumbprint = $thumb
                        NotAfter   = if ($cert) { $cert.NotAfter } else { $null }
                        Subject    = if ($cert) { $cert.Subject } else { "(certificado nao localizado no store)" }
                        Error      = $null
                    }
                }
            } catch {
                $out += [PSCustomObject]@{ Binding="(erro)"; Thumbprint=$null; NotAfter=$null; Error=$_.Exception.Message }
            }
            return $out
        }
        $params = @{ ComputerName = $ComputerName; ScriptBlock = $sb; ErrorAction = "Stop" }
        if ($Credential) { $params.Credential = $Credential }
        $results = Invoke-Command @params

        if (-not $results -or ($results.Count -eq 1 -and $results[0].Error -and $results[0].NotAfter -eq $null -and $results[0].Binding -eq "(nenhum)")) {
            $findings += New-Finding -Check "IIS Certificate" -Status "Info" -Value "No SSL binding" -FindingText "No HTTPS binding configured in IIS."
            return $findings
        }

        foreach ($r in $results) {
            if ($r.Error) {
                $findings += New-Finding -Check "IIS Certificate" -Status "NotApplicable" -FindingText "Failed to inspect IIS certificates." -Evidence $r.Error
                continue
            }
            if (-not $r.NotAfter) {
                $findings += New-Finding -Check "IIS Certificate ($($r.Binding))" -Status "Warning" -Value "Not found" -FindingText "Certificate for binding $($r.Binding) not found in the local store."
                continue
            }
            $daysLeft = [math]::Round(($r.NotAfter - (Get-Date)).TotalDays,0)
            $status = "Healthy"
            if ($daysLeft -le 0) { $status = "Critical" }
            elseif ($daysLeft -le $global:Thresholds.CertExpiryCriticalDays) { $status = "Critical" }
            elseif ($daysLeft -le $global:Thresholds.CertExpiryWarningDays) { $status = "Warning" }

            $findingText = if ($daysLeft -le 0) {
                "Certificate EXPIRED $([math]::Abs($daysLeft)) day(s) ago."
            } else {
                "Certificate expires in $daysLeft day(s) ($($r.NotAfter.ToString('yyyy-MM-dd')))."
            }
            $rec = if ($status -eq "Critical") { "Renew/replace the certificate urgently." }
                   elseif ($status -eq "Warning") { "Plan for certificate renewal." } else { "" }

            $findings += New-Finding -Check "IIS Certificate ($($r.Binding))" -Status $status -Value "$daysLeft days remaining" `
                -FindingText $findingText -Evidence "Subject=$($r.Subject); Thumbprint=$($r.Thumbprint)" -Recommendation $rec
        }
    } catch {
        $findings += New-Finding -Check "IIS Certificate" -Status "NotApplicable" -FindingText "Failed to connect via WinRM to check IIS certificates." -Evidence $_.Exception.Message
    }
    return $findings
}

function Get-WSUSHealth {
    param([string]$ComputerName, [PSCredential]$Credential)
    $findings = @()

    # Servico WsusService
    $svcFindings = Get-ServerServiceHealth -ComputerName $ComputerName -ServiceNames @("WsusService","W3SVC") -Credential $Credential
    $findings += $svcFindings

    # Ultima sincronizacao (requer modulo UpdateServices no host que executa a ferramenta, apontando remotamente)
    try {
        if (Get-Module -ListAvailable -Name UpdateServices) {
            Import-Module UpdateServices -ErrorAction Stop
            $wsus = Get-WsusServer -Name $ComputerName -PortNumber 8530 -ErrorAction Stop
            $subscription = $wsus.GetSubscription()
            $syncInfo = $subscription.GetLastSynchronizationInfo()
            $status = "Healthy"
            if ($syncInfo.Result -ne "Succeeded") { $status = "Critical" }
            $hoursAgo = [math]::Round(((Get-Date) - $syncInfo.EndTime).TotalHours,1)
            if ($hoursAgo -gt 48 -and $status -eq "Healthy") { $status = "Warning" }
            $findings += New-Finding -Check "WSUS - Last Synchronization" -Status $status `
                -Value "$($syncInfo.Result) ($hoursAgo h ago)" `
                -FindingText "Result: $($syncInfo.Result); End: $($syncInfo.EndTime)." `
                -Recommendation $(if ($status -ne "Healthy") { "Check the WSUS synchronization logs (SoftwareDistribution.log / WSUS console)." } else { "" })
        } else {
            $findings += New-Finding -Check "WSUS - Last Synchronization" -Status "Info" -Value "N/A" -FindingText "UpdateServices module (RSAT) not installed on the machine running this tool; sync details unavailable."
        }
    } catch {
        $findings += New-Finding -Check "WSUS - Last Synchronization" -Status "Warning" -FindingText "Failed to query WSUS synchronization status." -Evidence $_.Exception.Message
    }

    return $findings
}

# =====================================================================================
# REGIAO: STATUS HTML HELPERS
# =====================================================================================

function Get-StatusDotHtml {
    param([string]$Status)
    $map = @{
        "Healthy"       = @{ color="#22c55e"; label="Healthy" }
        "Warning"       = @{ color="#f59e0b"; label="Warning" }
        "Critical"      = @{ color="#ef4444"; label="Critical" }
        "Info"          = @{ color="#3b82f6"; label="Info" }
        "NotApplicable" = @{ color="#9ca3af"; label="Not Applicable" }
    }
    $s = $map[$Status]
    if (-not $s) { $s = $map["Info"] }
    return "<span class='status-badge'><span class='dot' style='background:$($s.color)'></span>$($s.label)</span>"
}

function ConvertTo-FindingsTableHtml {
    param([array]$Findings, [switch]$WithRecommendation)
    if (-not $Findings -or $Findings.Count -eq 0) {
        return "<p class='empty-note'>No data collected for this section.</p>"
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<table class='data-table'><thead><tr><th>Check</th><th>Status</th><th>Value</th><th>Finding</th><th>Evidence</th>")
    if ($WithRecommendation) { [void]$sb.Append("<th>Recommendation</th>") }
    [void]$sb.Append("</tr></thead><tbody>")
    foreach ($f in $Findings) {
        [void]$sb.Append("<tr class='row-$($f.Status)'>")
        [void]$sb.Append("<td>$([System.Web.HttpUtility]::HtmlEncode($f.Check))</td>")
        [void]$sb.Append("<td>$(Get-StatusDotHtml $f.Status)</td>")
        [void]$sb.Append("<td>$([System.Web.HttpUtility]::HtmlEncode($f.Value))</td>")
        [void]$sb.Append("<td>$([System.Web.HttpUtility]::HtmlEncode($f.Finding))</td>")
        [void]$sb.Append("<td class='muted'>$([System.Web.HttpUtility]::HtmlEncode($f.Evidence))</td>")
        if ($WithRecommendation) { [void]$sb.Append("<td>$([System.Web.HttpUtility]::HtmlEncode($f.Recommendation))</td>") }
        [void]$sb.Append("</tr>")
    }
    [void]$sb.Append("</tbody></table>")
    return $sb.ToString()
}

# =====================================================================================
# REGIAO: ORQUESTRACAO PRINCIPAL DA COLETA
# =====================================================================================

function Invoke-Assessment {
    param(
        [string]$SiteCode,
        [string]$SiteServer,
        [string]$OutputPath,
        [PSCredential]$Credential,
        [bool]$CheckAD = $true
    )

    Add-Type -AssemblyName System.Web

    Write-Log "Connecting to the SMS Provider on $SiteServer (site $SiteCode)..."
    $roles = Get-SiteSystemRoles -SiteCode $SiteCode -SiteServer $SiteServer
    if (-not $roles -or $roles.Count -eq 0) {
        Write-Log "No site system roles found. Check the Site Code / Site Server / permissions." "ERROR"
        throw "Could not retrieve site system roles. Please check the Site Code, Site Server, and your SMS Provider permissions."
    }

    $serverGroups = $roles | Group-Object ServerName
    Write-Log "Found $($serverGroups.Count) site system servers with $($roles.Count) role instances."

    $serverData = @()
    $i = 0
    foreach ($grp in $serverGroups) {
        $i++
        $serverName = $grp.Name
        $serverRoles = $grp.Group | Select-Object -ExpandProperty RoleName -Unique
        Write-Log "[$i/$($serverGroups.Count)] Collecting data from $serverName ($($serverRoles -join ', '))..."

        $connFindings, $winrmOk = Test-ServerConnectivity -ComputerName $serverName

        $osFindings = @()
        $disks = @()
        $svcFindings = @()
        $iisCertFindings = @()

        if ($winrmOk) {
            $osFindings = Get-ServerOSAndPerf -ComputerName $serverName -Credential $Credential
            $disks = Get-ServerDiskInfo -ComputerName $serverName -Credential $Credential

            $servicesToCheck = New-Object System.Collections.Generic.List[string]
            $servicesToCheck.Add("CcmExec") # cliente, se instalado no proprio servidor
            if ($serverRoles -contains "SMS Site Server") {
                $servicesToCheck.AddRange([string[]]@("SMS_EXECUTIVE","SMS_SITE_COMPONENT_MANAGER","SMS_SITE_VSS_WRITER"))
            }
            if ($serverRoles -contains "SMS Management Point" -or $serverRoles -contains "SMS Distribution Point" -or $serverRoles -contains "SMS Software Update Point" -or $serverRoles -contains "SMS Reporting Point") {
                $servicesToCheck.Add("W3SVC")
                $servicesToCheck.Add("WAS")
            }
            if ($serverRoles -contains "SMS Management Point") {
                $servicesToCheck.Add("SMS_EXECUTIVE")
            }
            if ($serverRoles -contains "SMS Software Update Point") {
                $servicesToCheck.Add("WsusService")
            }
            $svcFindings = Get-ServerServiceHealth -ComputerName $serverName -ServiceNames ($servicesToCheck | Select-Object -Unique) -Credential $Credential

            if ($serverRoles -contains "SMS Management Point" -or $serverRoles -contains "SMS Distribution Point" -or $serverRoles -contains "SMS Software Update Point") {
                $iisCertFindings = Get-IISCertHealth -ComputerName $serverName -Credential $Credential
            }
        } else {
            $osFindings += New-Finding -Check "OS Version" -Status "NotApplicable" -FindingText "WinRM unavailable."
        }

        $wsusFindings = @()
        if ($serverRoles -contains "SMS Software Update Point") {
            Write-Log "  Checking WSUS/SUP health on $serverName..."
            $wsusFindings = Get-WSUSHealth -ComputerName $serverName -Credential $Credential
        }

        $dpContentErrors = @()
        if ($serverRoles -contains "SMS Distribution Point") {
            $allContentErrors = $global:GlobalContentErrors
            if ($null -eq $allContentErrors) {
                $allContentErrors = Get-ContentDistributionErrors -SiteCode $SiteCode -SiteServer $SiteServer
                $global:GlobalContentErrors = $allContentErrors
            }
            $dpContentErrors = $allContentErrors | Where-Object { $_.Server -eq $serverName }
        }

        # Status agregado por secao
        $overviewStatus = Get-WorstStatus -Statuses ($connFindings.Status)
        $osStatus       = Get-WorstStatus -Statuses ($osFindings | Where-Object {$_.Check -ne 'OS Version'} | Select-Object -ExpandProperty Status)
        $storageStatus  = Get-WorstStatus -Statuses ($disks.Status)
        $svcStatus      = Get-WorstStatus -Statuses (($svcFindings + $iisCertFindings + $wsusFindings).Status)
        $dpStatus       = if ($serverRoles -contains "SMS Distribution Point") {
                              if ($dpContentErrors.Count -gt 0) { "Critical" } else { "Healthy" }
                          } else { "NotApplicable" }

        $overallStatus = Get-WorstStatus -Statuses @($overviewStatus,$osStatus,$storageStatus,$svcStatus,$dpStatus)

        $serverData += [PSCustomObject]@{
            ServerName       = $serverName
            Roles            = $serverRoles
            OverallStatus    = $overallStatus
            ConnFindings     = $connFindings
            OSFindings       = $osFindings
            Disks            = $disks
            ServiceFindings  = $svcFindings
            IISCertFindings  = $iisCertFindings
            WSUSFindings     = $wsusFindings
            DPContentErrors  = $dpContentErrors
            SectionStatus    = @{
                Overview = $overviewStatus
                OS       = $osStatus
                Storage  = $storageStatus
                Services = $svcStatus
                DP       = $dpStatus
            }
        }
    }

    Write-Log "Collecting boundaries without a group..."
    $orphanBoundaries = Get-BoundariesWithoutGroup -SiteCode $SiteCode -SiteServer $SiteServer

    Write-Log "Collecting content distribution errors (global)..."
    if ($null -eq $global:GlobalContentErrors) {
        $global:GlobalContentErrors = Get-ContentDistributionErrors -SiteCode $SiteCode -SiteServer $SiteServer
    }

    Write-Log "Collecting client health (inactive / check failed)..."
    $clientHealth = Get-ClientHealthIssues -SiteCode $SiteCode -SiteServer $SiteServer

    $devicesWithoutClient = [PSCustomObject]@{ Available=$false; Devices=@(); Note="Checagem desabilitada." }
    if ($CheckAD) {
        Write-Log "Cross-referencing Active Directory with SCCM clients (devices without client)..."
        $devicesWithoutClient = Get-DevicesWithoutClient -SiteCode $SiteCode -SiteServer $SiteServer -DaysBack $global:Thresholds.ADLogonDays
    }

    Write-Log "Generating HTML report..."
    $reportData = [PSCustomObject]@{
        SiteCode              = $SiteCode
        SiteServer            = $SiteServer
        GeneratedAt           = Get-Date
        Servers               = $serverData
        OrphanBoundaries      = $orphanBoundaries
        ContentErrors         = $global:GlobalContentErrors
        ClientHealth          = $clientHealth
        DevicesWithoutClient  = $devicesWithoutClient
    }

    $reportFile = Build-HtmlReport -Data $reportData -OutputPath $OutputPath
    Write-Log "Report generated at: $reportFile"
    return $reportFile
}

# =====================================================================================
# REGIAO: GERACAO DO RELATORIO HTML
# =====================================================================================

function Get-CssBlock {
    return @'
:root{
  --bg:#0f172a; --bg-soft:#f4f6fb; --card:#ffffff; --border:#e5e7eb;
  --text:#111827; --muted:#6b7280; --accent:#2563eb;
  --green:#22c55e; --amber:#f59e0b; --red:#ef4444; --blue:#3b82f6; --gray:#9ca3af;
}
*{box-sizing:border-box;}
body{margin:0;font-family:'Segoe UI',system-ui,-apple-system,Roboto,Arial,sans-serif;background:var(--bg-soft);color:var(--text);}
.header{background:linear-gradient(120deg,#0f172a,#1e293b);color:#fff;padding:22px 28px;}
.header h1{margin:0;font-size:26px;font-weight:700;letter-spacing:.3px;}
.header .meta{color:#94a3b8;font-size:13px;margin-top:6px;}
.layout{display:flex;gap:20px;padding:20px 28px 60px;align-items:flex-start;}
.sidebar{width:280px;flex:0 0 280px;position:sticky;top:20px;display:flex;flex-direction:column;gap:16px;}
.panel{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:16px;box-shadow:0 1px 2px rgba(0,0,0,.03);}
.panel h3{margin:0 0 12px;font-size:14px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted);}
.panel input[type=text],.panel select{width:100%;padding:9px 10px;border:1px solid var(--border);border-radius:8px;font-size:13px;margin-bottom:10px;background:#fff;}
.env-row{display:flex;justify-content:space-between;font-size:14px;padding:6px 0;border-bottom:1px dashed var(--border);}
.env-row:last-child{border-bottom:none;}
.env-row b{font-weight:700;}
.main{flex:1;min-width:0;display:flex;flex-direction:column;gap:18px;}
.section-title{font-size:18px;font-weight:700;margin:6px 0 -4px;}
.card{background:var(--card);border:1px solid var(--border);border-radius:14px;box-shadow:0 1px 3px rgba(0,0,0,.04);overflow:hidden;}
.card.border-Critical{border-left:5px solid var(--red);}
.card.border-Warning{border-left:5px solid var(--amber);}
.card.border-Healthy{border-left:5px solid var(--green);}
.card.border-Info{border-left:5px solid var(--blue);}
.card-body{padding:18px 22px;}
.card-header{display:flex;align-items:center;justify-content:space-between;padding:16px 22px;border-bottom:1px solid var(--border);}
.card-header h2{margin:0;font-size:17px;display:flex;align-items:center;gap:8px;}
.card-header h2 svg{opacity:.7}
.status-badge{display:inline-flex;align-items:center;gap:6px;font-size:12.5px;font-weight:600;padding:4px 10px;border-radius:999px;background:#f3f4f6;}
.status-badge .dot{width:9px;height:9px;border-radius:50%;display:inline-block;}
.role-badge{display:inline-block;background:#eef2ff;color:#4338ca;font-size:11.5px;font-weight:600;padding:3px 10px;border-radius:999px;margin:0 6px 6px 0;}
.tabs{display:flex;gap:8px;flex-wrap:wrap;padding:14px 22px 0;}
.tab-btn{border:1px solid var(--border);background:#fff;color:var(--text);padding:7px 14px;border-radius:999px;font-size:13px;cursor:pointer;font-weight:600;}
.tab-btn.active{background:var(--accent);border-color:var(--accent);color:#fff;}
.tab-btn.tab-Critical{background:#fef2f2;border-color:var(--red);color:#b91c1c;}
.tab-btn.tab-Critical.active{background:var(--red);color:#fff;}
.tab-btn.tab-Warning{background:#fffbeb;border-color:var(--amber);color:#92400e;}
.tab-btn.tab-Warning.active{background:var(--amber);color:#fff;}
.tab-content{display:none;padding:16px 22px 22px;}
.tab-content.active{display:block;}
.subheading{font-weight:700;font-size:14.5px;margin:14px 0 8px;}
.data-table{width:100%;border-collapse:collapse;font-size:13px;margin-bottom:6px;}
.data-table th{text-align:left;background:#f8fafc;color:var(--muted);font-weight:600;padding:8px 10px;border-bottom:1px solid var(--border);white-space:nowrap;}
.data-table td{padding:8px 10px;border-bottom:1px solid #f1f5f9;vertical-align:top;}
.data-table td.muted{color:var(--muted);font-size:12px;}
.data-table tr.row-Critical td:first-child{border-left:3px solid var(--red);}
.data-table tr.row-Warning td:first-child{border-left:3px solid var(--amber);}
.storage-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:14px;margin-bottom:10px;}
.disk-card{border:1px solid var(--border);border-radius:10px;padding:12px 14px;}
.disk-card.Critical{border-color:var(--red);background:#fef2f2;}
.disk-card.Warning{border-color:var(--amber);background:#fffbeb;}
.disk-card .dtop{display:flex;justify-content:space-between;align-items:center;font-weight:700;margin-bottom:8px;}
.bar-bg{width:100%;height:9px;background:#e5e7eb;border-radius:99px;overflow:hidden;}
.bar-fill{height:100%;border-radius:99px;}
.disk-note{font-size:12px;color:var(--muted);margin-top:6px;}
.empty-note{color:var(--muted);font-style:italic;font-size:13px;}
.search-hidden{display:none !important;}
.summary-cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;}
.summary-card{background:#fff;border:1px solid var(--border);border-radius:12px;padding:14px 16px;text-align:center;}
.summary-card .num{font-size:26px;font-weight:800;}
.summary-card .lbl{font-size:12px;color:var(--muted);margin-top:2px;}
.footer{text-align:center;color:var(--muted);font-size:12px;padding:20px;}
@media (max-width:900px){.layout{flex-direction:column;}.sidebar{width:100%;position:static;}}
'@
}

function Get-JsBlock {
    return @'
function switchTab(serverId, tabName, btn){
  const card = document.getElementById('server-'+serverId);
  card.querySelectorAll('.tab-content').forEach(el=>el.classList.remove('active'));
  card.querySelectorAll('.tab-btn').forEach(el=>el.classList.remove('active'));
  card.querySelector('#tab-'+serverId+'-'+tabName).classList.add('active');
  btn.classList.add('active');
}
function applyFilters(){
  const q = document.getElementById('searchServer').value.toLowerCase();
  const status = document.getElementById('statusFilter').value;
  const role = document.getElementById('roleFilter').value.toLowerCase();
  document.querySelectorAll('.server-card').forEach(card=>{
    const name = card.getAttribute('data-name').toLowerCase();
    const st = card.getAttribute('data-status');
    const roles = card.getAttribute('data-roles').toLowerCase();
    let show = true;
    if (q && !name.includes(q)) show = false;
    if (status !== 'all' && st !== status) show = false;
    if (role && !roles.includes(role)) show = false;
    card.classList.toggle('search-hidden', !show);
  });
}
document.addEventListener('DOMContentLoaded', function(){
  document.getElementById('searchServer').addEventListener('input', applyFilters);
  document.getElementById('statusFilter').addEventListener('change', applyFilters);
  document.getElementById('roleFilter').addEventListener('input', applyFilters);
});
'@
}

function Build-ServerCardHtml {
    param($Server)

    $sid = ($Server.ServerName -replace '[^a-zA-Z0-9]','_')
    $roleBadges = ($Server.Roles | ForEach-Object {
        $shortName = $global:RoleShortName[$_]
        if (-not $shortName) { $shortName = $_ }
        "<span class='role-badge'>$shortName</span>"
    }) -join ""

    # ---- Overview tab ----
    $overviewHtml = ConvertTo-FindingsTableHtml -Findings $Server.ConnFindings

    # ---- OS tab ----
    $osOnly    = $Server.OSFindings | Where-Object { $_.Check -in @('OS Version','Uptime','Pending Reboot') }
    $patchOnly = $Server.OSFindings | Where-Object { $_.Check -eq 'Last Installed Patch' }
    $perfOnly  = $Server.OSFindings | Where-Object { $_.Check -in @('Memory (RAM)','CPU Usage') }
    $osHtml  = "<div class='subheading'>Operating System</div>" + (ConvertTo-FindingsTableHtml -Findings $osOnly -WithRecommendation)
    $osHtml += "<div class='subheading'>Performance</div>" + (ConvertTo-FindingsTableHtml -Findings $perfOnly -WithRecommendation)
    $osHtml += "<div class='subheading'>Patch Evidence</div>" + (ConvertTo-FindingsTableHtml -Findings $patchOnly -WithRecommendation)

    # ---- Storage tab ----
    $storageCardsHtml = "<div class='storage-grid'>"
    foreach ($d in $Server.Disks) {
        $barColor = switch ($d.Status) { "Critical" {"var(--red)"} "Warning" {"var(--amber)"} default {"var(--green)"} }
        $storageCardsHtml += @"
<div class='disk-card $($d.Status)'>
  <div class='dtop'><span>Disk $($d.Drive)</span>$(Get-StatusDotHtml $d.Status)</div>
  <div class='bar-bg'><div class='bar-fill' style='width:$($d.FreePct)%;background:$barColor;'></div></div>
  <div class='disk-note'>Free: $($d.FreeGB) GB ($($d.FreePct)%) / Total: $($d.TotalGB) GB</div>
</div>
"@
    }
    $storageCardsHtml += "</div>"
    $diskFindings = $Server.Disks | ForEach-Object {
        New-Finding -Check "Disk $($_.Drive)" -Status $_.Status -Value "Total=$($_.TotalGB) GB; Used=$($_.UsedGB) GB; Free=$($_.FreeGB) GB; FreePct=$($_.FreePct)%" `
            -FindingText "Drive $($_.Drive) has $($_.FreeGB) GB free of $($_.TotalGB) GB ($($_.FreePct)% free)." `
            -Recommendation $_.Recommendation
    }
    $storageHtml = $storageCardsHtml + "<div class='subheading'>Storage Details</div>" + (ConvertTo-FindingsTableHtml -Findings $diskFindings -WithRecommendation)

    # ---- Services tab ----
    $servicesHtml  = "<div class='subheading'>Services</div>" + (ConvertTo-FindingsTableHtml -Findings $Server.ServiceFindings -WithRecommendation)
    if ($Server.IISCertFindings.Count -gt 0) {
        $servicesHtml += "<div class='subheading'>IIS Certificates</div>" + (ConvertTo-FindingsTableHtml -Findings $Server.IISCertFindings -WithRecommendation)
    }
    if ($Server.WSUSFindings.Count -gt 0) {
        $servicesHtml += "<div class='subheading'>WSUS / SUP</div>" + (ConvertTo-FindingsTableHtml -Findings $Server.WSUSFindings -WithRecommendation)
    }

    # ---- DP tab ----
    $hasDP = $Server.Roles -contains "SMS Distribution Point"
    $dpHtml = ""
    if ($hasDP) {
        if ($Server.DPContentErrors.Count -gt 0) {
            $dpFindings = $Server.DPContentErrors | ForEach-Object {
                New-Finding -Check "Content: $($_.PackageName)" -Status "Critical" -Value $_.State `
                    -FindingText "Package $($_.PackageName) is in state '$($_.State)' on this Distribution Point." `
                    -Evidence "LastUpdate=$($_.LastUpdate)" -Recommendation "Redistribute the content and validate the content library / DP connectivity."
            }
            $dpHtml = "<div class='subheading'>Content Distribution - Errors</div>" + (ConvertTo-FindingsTableHtml -Findings $dpFindings -WithRecommendation)
        } else {
            $dpHtml = "<p class='empty-note'>No content distribution errors found for this Distribution Point.</p>"
        }
    }

    # ---- Tabs (com destaque vermelho/amarelo se a secao tiver problema) ----
    $tabDef = @(
        @{ key="overview"; label="Overview"; status=$Server.SectionStatus.Overview; html=$overviewHtml },
        @{ key="os";       label="Operating System"; status=$Server.SectionStatus.OS; html=$osHtml },
        @{ key="storage";  label="Storage"; status=$Server.SectionStatus.Storage; html=$storageHtml },
        @{ key="services"; label="Services"; status=$Server.SectionStatus.Services; html=$servicesHtml }
    )
    if ($hasDP) {
        $tabDef += @{ key="dp"; label="Distribution Point"; status=$Server.SectionStatus.DP; html=$dpHtml }
    }

    $tabsBtnHtml = ""
    $tabsContentHtml = ""
    $first = $true
    foreach ($t in $tabDef) {
        $cls = "tab-btn"
        if ($t.status -eq "Critical") { $cls += " tab-Critical" }
        elseif ($t.status -eq "Warning") { $cls += " tab-Warning" }
        if ($first) { $cls += " active" }
        $tabsBtnHtml += "<button class='$cls' onclick=""switchTab('$sid','$($t.key)',this)"">$($t.label)</button>"
        $activeCls = if ($first) { "tab-content active" } else { "tab-content" }
        $tabsContentHtml += "<div id='tab-$sid-$($t.key)' class='$activeCls'>$($t.html)</div>"
        $first = $false
    }

    $rolesAttr = ($Server.Roles -join ",")
    $html = @"
<div class='card server-card border-$($Server.OverallStatus)' id='server-$sid' data-name='$($Server.ServerName)' data-status='$($Server.OverallStatus)' data-roles='$rolesAttr'>
  <div class='card-header'>
    <h2>$($Server.ServerName)</h2>
    $(Get-StatusDotHtml $Server.OverallStatus)
  </div>
  <div class='card-body' style='padding-bottom:0;'>
    $roleBadges
  </div>
  <div class='tabs'>$tabsBtnHtml</div>
  $tabsContentHtml
</div>
"@
    return $html
}

function Build-HtmlReport {
    param($Data, [string]$OutputPath)

    Add-Type -AssemblyName System.Web

    $assessmentId = [guid]::NewGuid().ToString().ToUpper()
    $generated = $Data.GeneratedAt.ToString("yyyy-MM-dd HH:mm:ss")

    $totalServers = $Data.Servers.Count
    $totalRoleInstances = ($Data.Servers | ForEach-Object { $_.Roles.Count } | Measure-Object -Sum).Sum
    $criticalServers = ($Data.Servers | Where-Object { $_.OverallStatus -eq "Critical" }).Count
    $warningServers  = ($Data.Servers | Where-Object { $_.OverallStatus -eq "Warning" }).Count

    $serverCardsHtml = ($Data.Servers | Sort-Object @{Expression={$global:StatusRank[$_.OverallStatus]}; Descending=$true}, ServerName |
        ForEach-Object { Build-ServerCardHtml -Server $_ }) -join "`n"

    # ---- Boundaries without group ----
    $boundaryFindings = $Data.OrphanBoundaries | ForEach-Object {
        New-Finding -Check "Boundary: $($_.DisplayName)" -Status "Warning" -Value $_.Value `
            -FindingText "Boundary '$($_.DisplayName)' (type $($_.BoundaryType)) does not belong to any boundary group." `
            -Recommendation "Associate it with a boundary group to ensure proper site assignment and content location."
    }
    $boundariesHtml = if ($boundaryFindings.Count -gt 0) {
        ConvertTo-FindingsTableHtml -Findings $boundaryFindings -WithRecommendation
    } else { "<p class='empty-note'>All boundaries are associated with at least one boundary group.</p>" }

    # ---- Content distribution (errors only, global) ----
    $contentFindings = $Data.ContentErrors | ForEach-Object {
        New-Finding -Check "$($_.PackageName) -> $($_.Server)" -Status "Critical" -Value $_.State `
            -FindingText "Distribution failure: $($_.State)." -Evidence "LastUpdate=$($_.LastUpdate)" `
            -Recommendation "Redistribute the content; validate the content library and Distribution Point connectivity."
    }
    $contentHtml = if ($contentFindings.Count -gt 0) {
        ConvertTo-FindingsTableHtml -Findings $contentFindings -WithRecommendation
    } else { "<p class='empty-note'>No content distribution errors found on any Distribution Point.</p>" }

    # ---- Inactive clients / client check failed ----
    $inactiveFindings = $Data.ClientHealth.Inactive | ForEach-Object {
        New-Finding -Check $_.Name -Status "Warning" -Value $_.ClientStateDescription `
            -FindingText "Inactive client. Last activity: $($_.LastActiveTime)."
    }
    $inactiveHtml = if ($inactiveFindings.Count -gt 0) {
        ConvertTo-FindingsTableHtml -Findings $inactiveFindings
    } else { "<p class='empty-note'>No inactive clients found.</p>" }

    $ccfFindings = $Data.ClientHealth.ClientCheckFailed | ForEach-Object {
        New-Finding -Check $_.Name -Status "Critical" -Value $_.ClientStateDescription `
            -FindingText "Client Check failed. Last activity: $($_.LastActiveTime)."
    }
    $ccfHtml = if ($ccfFindings.Count -gt 0) {
        ConvertTo-FindingsTableHtml -Findings $ccfFindings
    } else { "<p class='empty-note'>No devices with failed client check.</p>" }

    # ---- Devices without client (AD x SCCM) ----
    $dwcHtml = ""
    if (-not $Data.DevicesWithoutClient.Available) {
        $dwcHtml = "<p class='empty-note'>$([System.Web.HttpUtility]::HtmlEncode($Data.DevicesWithoutClient.Note))</p>"
    } else {
        $dwcFindings = $Data.DevicesWithoutClient.Devices | ForEach-Object {
            New-Finding -Check $_.Name -Status "Warning" -Value $_.LastLogon `
                -FindingText "The computer logged on to the domain in the last $($global:Thresholds.ADLogonDays) days but does not have an active SCCM client."
        }
        $dwcHtml = if ($dwcFindings.Count -gt 0) {
            ConvertTo-FindingsTableHtml -Findings $dwcFindings
        } else { "<p class='empty-note'>No devices with recent AD logon lacking an SCCM client.</p>" }
    }

    $css = Get-CssBlock
    $js  = Get-JsBlock

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>ConfigMgr Health Assessment - $($Data.SiteCode)</title>
<style>$css</style>
</head>
<body>
  <div class="header">
    <h1>ConfigMgr Infrastructure Health Assessment</h1>
    <div class="meta">Site: $($Data.SiteCode) | Site Server: $($Data.SiteServer) | Version $($global:AppVersion) | Assessment ID: $assessmentId | Generated: $generated</div>
  </div>
  <div class="layout">
    <div class="sidebar">
      <div class="panel">
        <h3>Filters</h3>
        <input type="text" id="searchServer" placeholder="Search server...">
        <select id="statusFilter">
          <option value="all">All statuses</option>
          <option value="Critical">Critical</option>
          <option value="Warning">Warning</option>
          <option value="Healthy">Healthy</option>
        </select>
        <input type="text" id="roleFilter" placeholder="Filter by role badge...">
      </div>
      <div class="panel">
        <h3>Environment</h3>
        <div class="env-row"><span>Site</span><b>$($Data.SiteCode)</b></div>
        <div class="env-row"><span>Servers</span><b>$totalServers</b></div>
        <div class="env-row"><span>Role Instances</span><b>$totalRoleInstances</b></div>
        <div class="env-row"><span>Critical Servers</span><b style="color:var(--red)">$criticalServers</b></div>
        <div class="env-row"><span>Warning Servers</span><b style="color:var(--amber)">$warningServers</b></div>
      </div>
    </div>
    <div class="main">
      <div class="summary-cards">
        <div class="summary-card"><div class="num">$totalServers</div><div class="lbl">Servers</div></div>
        <div class="summary-card"><div class="num" style="color:var(--red)">$criticalServers</div><div class="lbl">Critical</div></div>
        <div class="summary-card"><div class="num" style="color:var(--amber)">$warningServers</div><div class="lbl">Warning</div></div>
        <div class="summary-card"><div class="num" style="color:var(--red)">$($contentFindings.Count)</div><div class="lbl">Distribution Errors</div></div>
        <div class="summary-card"><div class="num" style="color:var(--amber)">$($boundaryFindings.Count)</div><div class="lbl">Boundaries w/o Group</div></div>
        <div class="summary-card"><div class="num" style="color:var(--red)">$($ccfFindings.Count)</div><div class="lbl">Client Check Failed</div></div>
      </div>

      <div class="section-title">Site System Servers</div>
      $serverCardsHtml

      <div class="section-title">Content Distribution Status (errors only)</div>
      <div class="card"><div class="card-body">$contentHtml</div></div>

      <div class="section-title">Boundaries without Boundary Group</div>
      <div class="card"><div class="card-body">$boundariesHtml</div></div>

      <div class="section-title">Devices without SCCM Client (AD logon in the last $($global:Thresholds.ADLogonDays) days)</div>
      <div class="card"><div class="card-body">$dwcHtml</div></div>

      <div class="section-title">Inactive Clients</div>
      <div class="card"><div class="card-body">$inactiveHtml</div></div>

      <div class="section-title">Client Check Failed</div>
      <div class="card"><div class="card-body">$ccfHtml</div></div>
    </div>
  </div>
  <div class="footer">Generated by $($global:AppName) v$($global:AppVersion) | $generated</div>
  <script>$js</script>
</body>
</html>
"@

    if (-not (Test-Path (Split-Path $OutputPath -Parent))) {
        New-Item -ItemType Directory -Path (Split-Path $OutputPath -Parent) -Force | Out-Null
    }
    $html | Out-File -FilePath $OutputPath -Encoding utf8
    return $OutputPath
}

# =====================================================================================
# REGIAO: GUI (WinForms)
# =====================================================================================

function Show-MainForm {

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$global:AppName v$global:AppVersion"
    $form.Size = New-Object System.Drawing.Size(860,600)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font("Segoe UI",9)

    $y = 20

    $lblSite = New-Object System.Windows.Forms.Label
    $lblSite.Text = "Site Code:"
    $lblSite.AutoSize = $true
    $lblSite.Location = New-Object System.Drawing.Point(20,$y)
    $form.Controls.Add($lblSite)

    $txtSiteCode = New-Object System.Windows.Forms.TextBox
    $txtSiteCode.Location = New-Object System.Drawing.Point(180,($y-3))
    $txtSiteCode.Size = New-Object System.Drawing.Size(100,22)
    $txtSiteCode.MaxLength = 3
    $form.Controls.Add($txtSiteCode)

    $y += 34
    $lblServer = New-Object System.Windows.Forms.Label
    $lblServer.Text = "Primary Site Server:"
    $lblServer.AutoSize = $true
    $lblServer.Location = New-Object System.Drawing.Point(20,$y)
    $form.Controls.Add($lblServer)

    $txtSiteServer = New-Object System.Windows.Forms.TextBox
    $txtSiteServer.Location = New-Object System.Drawing.Point(180,($y-3))
    $txtSiteServer.Size = New-Object System.Drawing.Size(400,22)
    $form.Controls.Add($txtSiteServer)

    $y += 40
    $chkAlt = New-Object System.Windows.Forms.CheckBox
    $chkAlt.Text = "Use alternate credentials for remote access to servers"
    $chkAlt.AutoSize = $true
    $chkAlt.Location = New-Object System.Drawing.Point(20,$y)
    $form.Controls.Add($chkAlt)

    $y += 30
    $chkAD = New-Object System.Windows.Forms.CheckBox
    $chkAD.Text = "Check devices without client (Active Directory cross-check, last $($global:Thresholds.ADLogonDays) days)"
    $chkAD.Checked = $true
    $chkAD.AutoSize = $true
    $chkAD.Location = New-Object System.Drawing.Point(20,$y)
    $form.Controls.Add($chkAD)

    $y += 36
    $lblOut = New-Object System.Windows.Forms.Label
    $lblOut.Text = "Save report to:"
    $lblOut.AutoSize = $true
    $lblOut.Location = New-Object System.Drawing.Point(20,$y)
    $form.Controls.Add($lblOut)

    $txtOut = New-Object System.Windows.Forms.TextBox
    $defaultOut = Join-Path ([Environment]::GetFolderPath("Desktop")) ("ConfigMgr-HealthReport_{0}.html" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $txtOut.Text = $defaultOut
    $txtOut.Location = New-Object System.Drawing.Point(180,($y-3))
    $txtOut.Size = New-Object System.Drawing.Size(590,22)
    $form.Controls.Add($txtOut)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = "..."
    $btnBrowse.Location = New-Object System.Drawing.Point(778,($y-4))
    $btnBrowse.Size = New-Object System.Drawing.Size(32,24)
    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = "HTML File (*.html)|*.html"
        $dlg.FileName = [System.IO.Path]::GetFileName($txtOut.Text)
        if ($dlg.ShowDialog() -eq "OK") { $txtOut.Text = $dlg.FileName }
    })
    $form.Controls.Add($btnBrowse)

    $y += 44
    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "Run Assessment"
    $btnRun.AutoSize = $true
    $btnRun.Padding = New-Object System.Windows.Forms.Padding(14,6,14,6)
    $btnRun.Location = New-Object System.Drawing.Point(20,$y)
    $btnRun.BackColor = [System.Drawing.Color]::FromArgb(37,99,235)
    $btnRun.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($btnRun)

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = "Open Report"
    $btnOpen.AutoSize = $true
    $btnOpen.Padding = New-Object System.Windows.Forms.Padding(14,6,14,6)
    $btnOpen.Location = New-Object System.Drawing.Point(210,$y)
    $btnOpen.Enabled = $false
    $form.Controls.Add($btnOpen)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(20,($y+42))
    $progress.Size = New-Object System.Drawing.Size(790,18)
    $progress.Style = "Marquee"
    $progress.MarqueeAnimationSpeed = 0
    $form.Controls.Add($progress)

    $y += 70
    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text = "Execution log:"
    $lblLog.AutoSize = $true
    $lblLog.Location = New-Object System.Drawing.Point(20,$y)
    $form.Controls.Add($lblLog)

    $y += 22
    $txtLog = New-Object System.Windows.Forms.RichTextBox
    $txtLog.Location = New-Object System.Drawing.Point(20,$y)
    $txtLog.Size = New-Object System.Drawing.Size(790,300)
    $txtLog.ReadOnly = $true
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(15,23,42)
    $txtLog.ForeColor = [System.Drawing.Color]::FromArgb(226,232,240)
    $txtLog.Font = New-Object System.Drawing.Font("Consolas",9)
    $form.Controls.Add($txtLog)

    $form.Size = New-Object System.Drawing.Size(860,($y+340))

    # ---- Estado compartilhado para thread de execucao ----
    $global:SyncHash = [hashtable]::Synchronized(@{
        LogQueue  = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Completed = $false
        Error     = $null
        ReportPath= $null
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 400
    $timer.Add_Tick({
        while ($global:SyncHash.LogQueue.Count -gt 0) {
            $line = $global:SyncHash.LogQueue[0]
            $global:SyncHash.LogQueue.RemoveAt(0)
            $txtLog.AppendText("$line`r`n")
            $txtLog.ScrollToCaret()
        }
        if ($global:SyncHash.Completed) {
            $timer.Stop()
            $progress.MarqueeAnimationSpeed = 0
            $btnRun.Enabled = $true
            if ($global:SyncHash.Error) {
                [System.Windows.Forms.MessageBox]::Show("Error during assessment:`n`n$($global:SyncHash.Error)","Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            } else {
                $btnOpen.Enabled = $true
                [System.Windows.Forms.MessageBox]::Show("Assessment completed successfully!`n`nReport: $($global:SyncHash.ReportPath)","Completed",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            }
        }
    })

    $btnRun.Add_Click({
        if ([string]::IsNullOrWhiteSpace($txtSiteCode.Text) -or [string]::IsNullOrWhiteSpace($txtSiteServer.Text)) {
            [System.Windows.Forms.MessageBox]::Show("Please provide the Site Code and Primary Site Server.","Required Fields",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $cred = $null
        if ($chkAlt.Checked) {
            $cred = Get-Credential -Message "Credentials for remote access to servers"
            if (-not $cred) { return }
        }

        $txtLog.Clear()
        $btnOpen.Enabled = $false
        $btnRun.Enabled = $false
        $global:SyncHash.Completed = $false
        $global:SyncHash.Error = $null
        $progress.MarqueeAnimationSpeed = 30
        $timer.Start()

        $siteCodeVal   = $txtSiteCode.Text.Trim()
        $siteServerVal = $txtSiteServer.Text.Trim()
        $outPathVal    = $txtOut.Text.Trim()
        $checkADVal    = $chkAD.Checked

        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        # SyncHash e o unico objeto que precisa atravessar a fronteira do runspace
        # (e o canal de comunicacao com a thread da UI); demais configuracoes sao
        # recriadas dentro do proprio runspace via Initialize-ScriptConfig para
        # garantir o escopo correto de $global: dentro das funcoes reinjetadas.
        $runspace.SessionStateProxy.SetVariable("SyncHash",$global:SyncHash)

        $ps = [powershell]::Create()
        $ps.Runspace = $runspace

        # Reinjeta todas as funcoes deste script no runspace de background
        $funcDefs = @(
            'Initialize-ScriptConfig','Write-Log','New-Finding','Get-WorstStatus','Invoke-SmsQuery','Get-SiteSystemRoles','Get-ContentDistributionErrors',
            'Get-BoundariesWithoutGroup','Get-DevicesWithoutClient','Get-ClientHealthIssues','New-RemoteCimSession',
            'Test-ServerConnectivity','Get-ServerOSAndPerf','Get-ServerPendingReboot','Get-ServerDiskInfo','Get-ServerServiceHealth',
            'Get-IISCertHealth','Get-WSUSHealth','Get-StatusDotHtml','ConvertTo-FindingsTableHtml','Invoke-Assessment',
            'Get-CssBlock','Get-JsBlock','Build-ServerCardHtml','Build-HtmlReport'
        )
        foreach ($fn in $funcDefs) {
            $def = Get-Item "function:\$fn"
            [void]$ps.AddScript("function $fn { $($def.Definition) }")
        }
        [void]$ps.AddScript({ Initialize-ScriptConfig })
        [void]$ps.AddScript({
            param($SiteCode,$SiteServer,$OutputPath,$Credential,$CheckAD)
            try {
                $reportPath = Invoke-Assessment -SiteCode $SiteCode -SiteServer $SiteServer -OutputPath $OutputPath -Credential $Credential -CheckAD $CheckAD
                $global:SyncHash.ReportPath = $reportPath
            } catch {
                $global:SyncHash.Error = $_.Exception.Message
            } finally {
                $global:SyncHash.Completed = $true
            }
        }).AddArgument($siteCodeVal).AddArgument($siteServerVal).AddArgument($outPathVal).AddArgument($cred).AddArgument($checkADVal)

        [void]$ps.BeginInvoke()
    })

    $btnOpen.Add_Click({
        if ($global:SyncHash.ReportPath -and (Test-Path $global:SyncHash.ReportPath)) {
            Start-Process $global:SyncHash.ReportPath
        }
    })

    [void]$form.ShowDialog()
}

# =====================================================================================
# ENTRY POINT
# =====================================================================================
Show-MainForm
