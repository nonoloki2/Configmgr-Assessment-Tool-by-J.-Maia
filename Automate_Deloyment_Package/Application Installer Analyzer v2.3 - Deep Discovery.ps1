#requires -version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:CurrentResults = @{}
$script:CurrentProgram = $null
$script:Diagnostics = New-Object System.Collections.Generic.List[string]

function Add-Diagnostic {
    param([string]$Text)
    $stamp = Get-Date -Format 'HH:mm:ss'
    $script:Diagnostics.Add("[$stamp] $Text")
}

function Safe-String { param($Value) if ($null -eq $Value) { return '' } return [string]$Value }

function New-ProgramObject {
    param(
        [string]$DisplayName,
        [string]$DisplayVersion,
        [string]$Publisher,
        [string]$UninstallString,
        [string]$QuietUninstallString,
        [string]$InstallLocation,
        [string]$InstallSource,
        [string]$DisplayIcon,
        [string]$KeyName,
        [string]$RegistryPath,
        [string]$RegistryView,
        [string]$DiscoveryEngine,
        [string]$BundleCachePath,
        [string]$BundleProviderKey,
        [object]$WindowsInstaller,
        [object]$SystemComponent
    )
    [pscustomobject]@{
        DisplayName          = $DisplayName
        DisplayVersion       = $DisplayVersion
        Publisher            = $Publisher
        UninstallString      = $UninstallString
        QuietUninstallString = $QuietUninstallString
        InstallLocation      = $InstallLocation
        InstallSource        = $InstallSource
        DisplayIcon          = $DisplayIcon
        PSChildName          = $KeyName
        RegistryPath         = $RegistryPath
        RegistryView         = $RegistryView
        DiscoveryEngine      = $DiscoveryEngine
        BundleCachePath      = $BundleCachePath
        BundleProviderKey    = $BundleProviderKey
        WindowsInstaller     = $WindowsInstaller
        SystemComponent      = $SystemComponent
    }
}

function Get-ArpViaProvider {
    $results = New-Object System.Collections.Generic.List[object]
    $paths = @(
        @{ Path='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; View='Provider / HKLM' },
        @{ Path='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; View='Provider / WOW6432Node' },
        @{ Path='Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; View='Provider / HKCU' }
    )

    foreach ($p in $paths) {
        try {
            $items = @(Get-ItemProperty -Path $p.Path -ErrorAction Stop)
            Add-Diagnostic "Registry provider: $($p.View) returned $($items.Count) entries."
            foreach ($i in $items) {
                if ([string]::IsNullOrWhiteSpace([string]$i.DisplayName)) { continue }
                $results.Add((New-ProgramObject `
                    -DisplayName (Safe-String $i.DisplayName) `
                    -DisplayVersion (Safe-String $i.DisplayVersion) `
                    -Publisher (Safe-String $i.Publisher) `
                    -UninstallString (Safe-String $i.UninstallString) `
                    -QuietUninstallString (Safe-String $i.QuietUninstallString) `
                    -InstallLocation (Safe-String $i.InstallLocation) `
                    -InstallSource (Safe-String $i.InstallSource) `
                    -DisplayIcon (Safe-String $i.DisplayIcon) `
                    -KeyName (Safe-String $i.PSChildName) `
                    -RegistryPath (Safe-String $i.PSPath) `
                    -RegistryView $p.View `
                    -DiscoveryEngine 'PowerShell Registry Provider' `
                    -BundleCachePath (Safe-String $i.BundleCachePath) `
                    -BundleProviderKey (Safe-String $i.BundleProviderKey) `
                    -WindowsInstaller $i.WindowsInstaller `
                    -SystemComponent $i.SystemComponent))
            }
        } catch {
            Add-Diagnostic "Registry provider FAILED for $($p.View): $($_.Exception.Message)"
        }
    }
    return @($results)
}

function Parse-RegQueryOutput {
    param([string[]]$Lines, [string]$ViewLabel)
    $results = New-Object System.Collections.Generic.List[object]
    $currentKey = $null
    $values = @{}

    function Flush-RegRecord {
        param([string]$Key, [hashtable]$Vals, [string]$View)
        if (-not $Key) { return $null }
        if ([string]::IsNullOrWhiteSpace([string]$Vals['DisplayName'])) { return $null }
        return New-ProgramObject `
            -DisplayName (Safe-String $Vals['DisplayName']) `
            -DisplayVersion (Safe-String $Vals['DisplayVersion']) `
            -Publisher (Safe-String $Vals['Publisher']) `
            -UninstallString (Safe-String $Vals['UninstallString']) `
            -QuietUninstallString (Safe-String $Vals['QuietUninstallString']) `
            -InstallLocation (Safe-String $Vals['InstallLocation']) `
            -InstallSource (Safe-String $Vals['InstallSource']) `
            -DisplayIcon (Safe-String $Vals['DisplayIcon']) `
            -KeyName ([IO.Path]::GetFileName($Key)) `
            -RegistryPath $Key `
            -RegistryView $View `
            -DiscoveryEngine 'reg.exe' `
            -BundleCachePath (Safe-String $Vals['BundleCachePath']) `
            -BundleProviderKey (Safe-String $Vals['BundleProviderKey']) `
            -WindowsInstaller $Vals['WindowsInstaller'] `
            -SystemComponent $Vals['SystemComponent']
    }

    foreach ($line in $Lines) {
        if ($line -match '^HKEY_') {
            $obj = Flush-RegRecord -Key $currentKey -Vals $values -View $ViewLabel
            if ($obj) { $results.Add($obj) }
            $currentKey = $line.Trim()
            $values = @{}
            continue
        }
        if ($currentKey -and $line -match '^\s{2,}([^\s]+)\s+(REG_[A-Z0-9_]+)\s*(.*)$') {
            $values[$Matches[1]] = $Matches[3]
        }
    }
    $obj = Flush-RegRecord -Key $currentKey -Vals $values -View $ViewLabel
    if ($obj) { $results.Add($obj) }
    return @($results)
}

function Invoke-RegQuery {
    param([string]$Root, [string]$Switch, [string]$Label)
    try {
        $args = @('query', $Root, '/s')
        if ($Switch) { $args += $Switch }
        $out = & "$env:SystemRoot\System32\reg.exe" @args 2>&1
        $exit = $LASTEXITCODE
        if ($exit -ne 0) {
            Add-Diagnostic "reg.exe $Label returned exit code $exit."
            return @()
        }
        $parsed = @(Parse-RegQueryOutput -Lines $out -ViewLabel $Label)
        Add-Diagnostic "reg.exe $Label returned $($parsed.Count) ARP entries."
        return $parsed
    } catch {
        Add-Diagnostic "reg.exe FAILED for $Label: $($_.Exception.Message)"
        return @()
    }
}

function Get-ArpViaRegExe {
    $all = New-Object System.Collections.Generic.List[object]
    $root = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($o in @(Invoke-RegQuery -Root $root -Switch '/reg:64' -Label 'reg.exe /reg:64')) { $all.Add($o) }
    foreach ($o in @(Invoke-RegQuery -Root $root -Switch '/reg:32' -Label 'reg.exe /reg:32')) { $all.Add($o) }
    foreach ($o in @(Invoke-RegQuery -Root 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -Switch '' -Label 'reg.exe HKCU')) { $all.Add($o) }
    return @($all)
}

function Merge-Programs {
    param([object[]]$Programs)
    $map = @{}
    foreach ($p in $Programs) {
        if (-not $p.DisplayName) { continue }
        $key = "{0}|{1}|{2}" -f $p.DisplayName,$p.DisplayVersion,$p.UninstallString
        if (-not $map.ContainsKey($key)) { $map[$key] = $p }
        else {
            if ($map[$key].DiscoveryEngine -notmatch [regex]::Escape($p.DiscoveryEngine)) {
                $map[$key].DiscoveryEngine = "$($map[$key].DiscoveryEngine) + $($p.DiscoveryEngine)"
            }
        }
    }
    return @($map.Values | Sort-Object DisplayName, DisplayVersion)
}

function Get-AllInstalledPrograms {
    $script:Diagnostics.Clear()
    Add-Diagnostic "PowerShell: $($PSVersionTable.PSVersion); 64-bit process: $([Environment]::Is64BitProcess); 64-bit OS: $([Environment]::Is64BitOperatingSystem)"
    $all = @()
    $all += @(Get-ArpViaProvider)
    $all += @(Get-ArpViaRegExe)
    $merged = @(Merge-Programs -Programs $all)
    Add-Diagnostic "Merged unique ARP entries: $($merged.Count)."
    return $merged
}

function Test-Match {
    param($Program, [string]$Filter)
    if ([string]::IsNullOrWhiteSpace($Filter)) { return $true }
    $hay = @($Program.DisplayName,$Program.DisplayVersion,$Program.Publisher,$Program.UninstallString,$Program.QuietUninstallString,$Program.InstallLocation,$Program.RegistryPath) -join ' '
    foreach ($token in @($Filter -split '\s+' | Where-Object { $_ })) {
        if ($hay -notmatch [regex]::Escape($token)) { return $false }
    }
    return $true
}

function Get-ProductCode {
    param($Program)
    $candidates = @($Program.PSChildName,$Program.UninstallString,$Program.QuietUninstallString)
    foreach ($c in $candidates) {
        if ($c -and $c -match '(\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\})') { return $Matches[1].ToUpperInvariant() }
    }
    return ''
}

function Split-ExeCommand {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return [pscustomobject]@{Exe='';Args=''} }
    $cmd = $Command.Trim()
    if ($cmd.StartsWith('"')) {
        $m = [regex]::Match($cmd, '^"([^"]+)"\s*(.*)$')
        if ($m.Success) { return [pscustomobject]@{Exe=$m.Groups[1].Value;Args=$m.Groups[2].Value} }
    }
    $m = [regex]::Match($cmd, '^(.+?\.exe)\s*(.*)$','IgnoreCase')
    if ($m.Success) { return [pscustomobject]@{Exe=$m.Groups[1].Value.Trim();Args=$m.Groups[2].Value} }
    return [pscustomobject]@{Exe='';Args=$cmd}
}

function Get-Recommendation {
    param($Program)
    $quiet = Safe-String $Program.QuietUninstallString
    if ($quiet) {
        return [pscustomobject]@{ Command=$quiet; Confidence='VERY HIGH'; Reason='QuietUninstallString is explicitly registered by the application.' }
    }

    $productCode = Get-ProductCode $Program
    $uninstall = Safe-String $Program.UninstallString
    if (($Program.WindowsInstaller -eq 1) -or ($uninstall -match '(?i)msiexec') -or $productCode) {
        if ($productCode) {
            return [pscustomobject]@{ Command="msiexec.exe /x $productCode /qn /norestart"; Confidence='VERY HIGH'; Reason='Windows Installer ProductCode detected.' }
        }
    }

    if ($Program.DisplayName -match '(?i)MicroStation' -or $Program.Publisher -match '(?i)Bentley') {
        $parts = Split-ExeCommand $uninstall
        $exe = $parts.Exe
        if ($exe -and (Test-Path -LiteralPath $exe) -and ([IO.Path]::GetFileName($exe) -match '(?i)^Setup_.*\.exe$')) {
            return [pscustomobject]@{ Command=('"' + $exe + '" -Uninstall -Quiet'); Confidence='HIGH'; Reason='Bentley bootstrapper found in registered UninstallString; Bentley documents -Uninstall -Quiet for MicroStation.' }
        }
        if ($Program.BundleCachePath -and (Test-Path -LiteralPath $Program.BundleCachePath)) {
            return [pscustomobject]@{ Command=('"' + $Program.BundleCachePath + '" -Uninstall -Quiet'); Confidence='HIGH'; Reason='Bentley BundleCachePath exists; using Bentley silent uninstall switches.' }
        }
    }

    if ($uninstall) {
        return [pscustomobject]@{ Command=$uninstall; Confidence='DISCOVERED / NOT SILENT'; Reason='Only UninstallString was found. No silent switch is being guessed.' }
    }
    return [pscustomobject]@{ Command=''; Confidence='UNKNOWN'; Reason='No uninstall command was found in this registration.' }
}

function Get-FileInfoSafe {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $f = Get-Item -LiteralPath $Path -ErrorAction Stop
        $v = $f.VersionInfo
        [pscustomobject]@{ FullName=$f.FullName; ProductName=$v.ProductName; CompanyName=$v.CompanyName; FileDescription=$v.FileDescription; OriginalFilename=$v.OriginalFilename; FileVersion=$v.FileVersion; ProductVersion=$v.ProductVersion }
    } catch { return $null }
}

function Get-PackageCacheCandidates {
    param($Program)
    $root = 'C:\ProgramData\Package Cache'
    if (-not (Test-Path $root)) { return @() }
    $tokens = @([regex]::Matches(($Program.DisplayName + ' ' + $Program.Publisher), '[A-Za-z0-9]{4,}') | ForEach-Object { $_.Value.ToLowerInvariant() } | Select-Object -Unique)
    $items = New-Object System.Collections.Generic.List[object]
    try {
        $files = @(Get-ChildItem -Path $root -Filter *.exe -Recurse -File -ErrorAction SilentlyContinue)
        Add-Diagnostic "Package Cache executable count: $($files.Count)."
        foreach ($f in $files) {
            $meta = Get-FileInfoSafe $f.FullName
            $text = @($f.Name,$meta.ProductName,$meta.CompanyName,$meta.FileDescription,$meta.OriginalFilename) -join ' '
            $score = 0
            foreach ($t in $tokens) { if ($text -match [regex]::Escape($t)) { $score += 20 } }
            if ($Program.DisplayName -match '(?i)MicroStation' -and $text -match '(?i)MicroStation') { $score += 60 }
            if ($Program.Publisher -match '(?i)Bentley' -and $text -match '(?i)Bentley') { $score += 10 }
            if ($text -match '(?i)CONNECTION\s*Client' -and $Program.DisplayName -match '(?i)MicroStation') { $score -= 50 }
            if ($score -gt 0) {
                $items.Add([pscustomobject]@{Score=$score;Path=$f.FullName;Meta=$meta;Text=$text})
            }
        }
    } catch { Add-Diagnostic "Package Cache scan error: $($_.Exception.Message)" }
    return @($items | Sort-Object Score -Descending | Select-Object -First 50)
}

function Show-Program {
    param($Program)
    $script:CurrentProgram = $Program
    $rec = Get-Recommendation $Program
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Name               : $($Program.DisplayName)")
    $lines.Add("Version            : $($Program.DisplayVersion)")
    $lines.Add("Publisher          : $($Program.Publisher)")
    $lines.Add("Discovery engine   : $($Program.DiscoveryEngine)")
    $lines.Add("Registry view      : $($Program.RegistryView)")
    $lines.Add("Registry path      : $($Program.RegistryPath)")
    $lines.Add("Key / ProductCode  : $($Program.PSChildName)")
    $lines.Add("")
    $lines.Add("UninstallString      : $($Program.UninstallString)")
    $lines.Add("QuietUninstallString : $($Program.QuietUninstallString)")
    $lines.Add("BundleCachePath      : $($Program.BundleCachePath)")
    $lines.Add("BundleProviderKey    : $($Program.BundleProviderKey)")
    $lines.Add("InstallLocation      : $($Program.InstallLocation)")
    $lines.Add("InstallSource        : $($Program.InstallSource)")
    $lines.Add("DisplayIcon          : $($Program.DisplayIcon)")
    $lines.Add("")
    $lines.Add("Confidence           : $($rec.Confidence)")
    $lines.Add("Reason               : $($rec.Reason)")
    $txtDetails.Text = $lines -join "`r`n"
    $txtCommand.Text = $rec.Command
    $status.Text = "Selected: $($Program.DisplayName) | $($rec.Confidence)"
}

function Load-Programs {
    param([string]$Filter)
    $lst.Items.Clear(); $script:CurrentResults.Clear(); $txtDetails.Clear(); $txtCommand.Clear(); $lstCache.Items.Clear(); $script:CurrentProgram=$null
    $status.Text='Discovering installed applications with multiple engines...'; $form.Refresh()
    $all = @(Get-AllInstalledPrograms)
    $filtered = @($all | Where-Object { Test-Match $_ $Filter })
    if ($filtered.Count -eq 0) {
        $status.Text = "No match for '$Filter'. Click Diagnostics to see what each discovery engine returned."
        [System.Windows.Forms.MessageBox]::Show("No registration matched '$Filter'.`r`n`r`nThis version does NOT hide the discovery errors. Click Diagnostics to see exactly what the registry engines returned.",'Analyzer v2.3','OK','Warning') | Out-Null
        return
    }
    $n=0
    foreach($p in $filtered){
        $n++
        $label="[$n] $($p.DisplayName)"
        if($p.DisplayVersion){$label+="  v$($p.DisplayVersion)"}
        if($p.Publisher){$label+="  | $($p.Publisher)"}
        $label+="  [$($p.RegistryView)]"
        $lst.Items.Add($label)|Out-Null
        $script:CurrentResults[$label]=$p
    }
    $status.Text="$($filtered.Count) match(es); $($all.Count) unique ARP entries discovered."
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Application Installer Analyzer v2.3 - Deep Discovery'
$form.Size = New-Object System.Drawing.Size(1300,900)
$form.StartPosition='CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(1100,760)

$lbl = New-Object System.Windows.Forms.Label; $lbl.Text='Software name (or part of the name):'; $lbl.SetBounds(20,18,250,24)
$txtSearch = New-Object System.Windows.Forms.TextBox; $txtSearch.SetBounds(20,45,530,28); $txtSearch.Text='microstation'
$btnSearch = New-Object System.Windows.Forms.Button; $btnSearch.Text='Search'; $btnSearch.SetBounds(565,43,110,32)
$btnAll = New-Object System.Windows.Forms.Button; $btnAll.Text='Enumerate All'; $btnAll.SetBounds(685,43,120,32)
$btnDeep = New-Object System.Windows.Forms.Button; $btnDeep.Text='Deep Scan'; $btnDeep.SetBounds(815,43,110,32)
$btnCache = New-Object System.Windows.Forms.Button; $btnCache.Text='Package Cache'; $btnCache.SetBounds(935,43,120,32)
$btnDiag = New-Object System.Windows.Forms.Button; $btnDiag.Text='Diagnostics'; $btnDiag.SetBounds(1065,43,110,32)

$lst = New-Object System.Windows.Forms.ListBox; $lst.SetBounds(20,90,1155,180); $lst.HorizontalScrollbar=$true
$grp = New-Object System.Windows.Forms.GroupBox; $grp.Text='Analysis'; $grp.SetBounds(20,285,1155,315)
$txtDetails = New-Object System.Windows.Forms.TextBox; $txtDetails.Multiline=$true; $txtDetails.ReadOnly=$true; $txtDetails.ScrollBars='Both'; $txtDetails.WordWrap=$false; $txtDetails.SetBounds(15,28,1125,270); $grp.Controls.Add($txtDetails)
$lblCmd = New-Object System.Windows.Forms.Label; $lblCmd.Text='Recommended / discovered command:'; $lblCmd.SetBounds(20,615,270,24)
$txtCommand = New-Object System.Windows.Forms.TextBox; $txtCommand.ReadOnly=$true; $txtCommand.SetBounds(20,640,990,28)
$btnCopy = New-Object System.Windows.Forms.Button; $btnCopy.Text='Copy Command'; $btnCopy.SetBounds(1020,638,155,32)
$grpCache = New-Object System.Windows.Forms.GroupBox; $grpCache.Text='Package Cache candidates (double-click to inspect)'; $grpCache.SetBounds(20,680,1155,125)
$lstCache = New-Object System.Windows.Forms.ListBox; $lstCache.SetBounds(15,25,1125,80); $lstCache.HorizontalScrollbar=$true; $grpCache.Controls.Add($lstCache)
$status = New-Object System.Windows.Forms.Label; $status.Text='Ready.'; $status.AutoEllipsis=$true; $status.SetBounds(20,818,1155,24)

$form.Controls.AddRange(@($lbl,$txtSearch,$btnSearch,$btnAll,$btnDeep,$btnCache,$btnDiag,$lst,$grp,$lblCmd,$txtCommand,$btnCopy,$grpCache,$status))

$btnSearch.Add_Click({ Load-Programs -Filter $txtSearch.Text.Trim() })
$btnAll.Add_Click({ Load-Programs -Filter '' })
$btnDeep.Add_Click({
    Load-Programs -Filter $txtSearch.Text.Trim()
    if($lst.Items.Count -eq 1){$lst.SelectedIndex=0}
})
$lst.Add_SelectedIndexChanged({ if($lst.SelectedItem){ $p=$script:CurrentResults[[string]$lst.SelectedItem]; if($p){Show-Program $p} } })
$btnCopy.Add_Click({ if($txtCommand.Text){ [Windows.Forms.Clipboard]::SetText($txtCommand.Text); $status.Text='Command copied.' } })
$btnDiag.Add_Click({
    $dlg=New-Object System.Windows.Forms.Form; $dlg.Text='Discovery Diagnostics'; $dlg.Size=New-Object Drawing.Size(1000,650); $dlg.StartPosition='CenterParent'
    $t=New-Object Windows.Forms.TextBox; $t.Multiline=$true; $t.ReadOnly=$true; $t.ScrollBars='Both'; $t.WordWrap=$false; $t.Dock='Fill'; $t.Text=$script:Diagnostics -join "`r`n"; $dlg.Controls.Add($t); [void]$dlg.ShowDialog($form)
})
$btnCache.Add_Click({
    if(-not $script:CurrentProgram){
        $matches=@(Get-AllInstalledPrograms | Where-Object { Test-Match $_ $txtSearch.Text.Trim() })
        if($matches.Count -gt 0){$script:CurrentProgram=$matches[0]}
    }
    if(-not $script:CurrentProgram){[Windows.Forms.MessageBox]::Show('Select an application first.','Analyzer v2.3','OK','Information')|Out-Null; return}
    $lstCache.Items.Clear(); $status.Text='Scanning Package Cache...'; $form.Refresh()
    $cands=@(Get-PackageCacheCandidates $script:CurrentProgram)
    if($cands.Count -eq 0){$status.Text='No correlated executable found in Package Cache.'; return}
    foreach($c in $cands){
        $tag = if($c.Score -ge 80){'VERY HIGH'}elseif($c.Score -ge 50){'HIGH'}elseif($c.Score -ge 20){'MEDIUM'}else{'LOW'}
        $lstCache.Items.Add("Score $($c.Score) [$tag]  $($c.Path)  | $($c.Meta.ProductName) | $($c.Meta.CompanyName)")|Out-Null
    }
    $script:CacheCandidates=$cands
    $status.Text="$($cands.Count) Package Cache candidate(s) shown."
})
$lstCache.Add_DoubleClick({
    if($lstCache.SelectedIndex -lt 0){return}
    $c=$script:CacheCandidates[$lstCache.SelectedIndex]
    $msg="Path: $($c.Path)`r`nScore: $($c.Score)`r`nProduct: $($c.Meta.ProductName)`r`nCompany: $($c.Meta.CompanyName)`r`nDescription: $($c.Meta.FileDescription)`r`nOriginal filename: $($c.Meta.OriginalFilename)`r`nVersion: $($c.Meta.ProductVersion)"
    [Windows.Forms.MessageBox]::Show($msg,'Package Cache evidence','OK','Information')|Out-Null
})

[void]$form.ShowDialog()
