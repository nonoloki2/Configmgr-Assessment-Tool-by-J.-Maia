#Requires -Version 5.1
<#+
    Application Installer Analyzer v2.2
    --------------------------
    Packaging/SCCM-oriented installer and uninstall command analyzer.

    v2.2 Native Registry Accuracy:
      - Product-aware Package Cache correlation.
      - Strong penalties for same-vendor/different-product false positives.
      - Authenticode signature inspection for cached bootstrapper candidates.
      - Bentley logic only applies MicroStation switches to actual MicroStation identity.
      - Cache candidates now carry affinity/confidence instead of a raw vendor score.

    Goals:
      - Enumerate uninstall registrations from HKLM 64-bit, HKLM 32-bit and HKCU.
      - Prefer vendor-provided QuietUninstallString whenever available.
      - Normalize MSI uninstall commands safely.
      - Detect common installer families without blindly inventing switches.
      - Inspect cached bootstrapper executables under C:\ProgramData\Package Cache.
      - Add Bentley/MicroStation-aware analysis for cached Setup_*.exe bootstrapper.
      - Show confidence, source, evidence and warnings for every suggestion.
      - Never execute an uninstall command automatically.

    Recommended usage:
      Run elevated when packaging software for SCCM/ConfigMgr.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# -----------------------------------------------------------------------------
# Utility helpers
# -----------------------------------------------------------------------------

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Expand-CommandPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    try { return [Environment]::ExpandEnvironmentVariables($Path.Trim()) } catch { return $Path.Trim() }
}

function Split-CommandLine {
    param([string]$CommandLine)

    $result = [ordered]@{ Exe = $null; Arguments = $null }
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return [pscustomobject]$result }

    $s = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())

    if ($s -match '^\s*"([^"]+\.exe)"\s*(.*)$') {
        $result.Exe = $Matches[1]
        $result.Arguments = $Matches[2].Trim()
    }
    elseif ($s -match '^\s*([^\s]+\.exe)\s*(.*)$') {
        $result.Exe = $Matches[1]
        $result.Arguments = $Matches[2].Trim()
    }
    elseif ($s -match '^\s*(msiexec(?:\.exe)?)\s*(.*)$') {
        $result.Exe = 'msiexec.exe'
        $result.Arguments = $Matches[2].Trim()
    }

    [pscustomobject]$result
}

function Get-FileMetadata {
    param([string]$Path)

    if (-not $Path) { return $null }
    $expanded = Expand-CommandPath $Path
    if (-not (Test-Path -LiteralPath $expanded -PathType Leaf)) { return $null }

    try {
        $f = Get-Item -LiteralPath $expanded -ErrorAction Stop
        $v = $f.VersionInfo
        return [pscustomobject]@{
            Path            = $f.FullName
            CompanyName     = $v.CompanyName
            ProductName     = $v.ProductName
            FileDescription = $v.FileDescription
            FileVersion     = $v.FileVersion
            ProductVersion  = $v.ProductVersion
            OriginalFilename= $v.OriginalFilename
        }
    } catch { return $null }
}

function Test-CommandHasSilentSwitch {
    param([string]$CommandLine)
    if (-not $CommandLine) { return $false }

    $patterns = @(
        '(?i)(^|\s)/qn(\s|$)',
        '(?i)(^|\s)/quiet(\s|$)',
        '(?i)(^|\s)/q(\s|$)',
        '(?i)(^|\s)/s(\s|$)',
        '(?i)(^|\s)/silent(\s|$)',
        '(?i)(^|\s)/verysilent(\s|$)',
        '(?i)(^|\s)-quiet(\s|$)',
        '(?i)(^|\s)-silent(\s|$)',
        '(?i)(^|\s)--quiet(\s|$)',
        '(?i)(^|\s)--silent(\s|$)'
    )
    foreach ($p in $patterns) { if ($CommandLine -match $p) { return $true } }
    return $false
}

function Get-ProductCodeFromEntry {
    param($Program)

    $candidates = @($Program.PSChildName, $Program.UninstallString, $Program.QuietUninstallString)
    foreach ($candidate in $candidates) {
        if ($candidate -and $candidate -match '(\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\})') {
            return $Matches[1].ToUpperInvariant()
        }
    }
    return $null
}

function Convert-RegistryValueKindSafe {
    param($Key, [string]$Name)
    try { return $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    catch { try { return $Key.GetValue($Name) } catch { return $null } }
}

function Get-InstalledProgramsNative {
    <#
      Enumerates ARP entries using Microsoft.Win32.RegistryKey with an explicit
      RegistryView. This avoids WOW64 redirection ambiguity when the tool itself
      is started from 32-bit PowerShell.
    #>
    $targets = @(
        [pscustomobject]@{ Hive=[Microsoft.Win32.RegistryHive]::LocalMachine; HiveName='HKLM'; View=[Microsoft.Win32.RegistryView]::Registry64; ViewName='64-bit'; SubKey='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
        [pscustomobject]@{ Hive=[Microsoft.Win32.RegistryHive]::LocalMachine; HiveName='HKLM'; View=[Microsoft.Win32.RegistryView]::Registry32; ViewName='32-bit'; SubKey='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
        [pscustomobject]@{ Hive=[Microsoft.Win32.RegistryHive]::CurrentUser;  HiveName='HKCU'; View=[Microsoft.Win32.RegistryView]::Default;    ViewName='Current user'; SubKey='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
    )

    $propertyNames = @(
        'DisplayName','DisplayVersion','Publisher','InstallLocation','InstallSource','DisplayIcon',
        'UninstallString','QuietUninstallString','ModifyPath','RepairPath','URLInfoAbout','HelpLink',
        'InstallDate','EstimatedSize','WindowsInstaller','SystemComponent','NoRemove','NoModify',
        'NoRepair','VersionMajor','VersionMinor','Version','BundleCachePath','BundleProviderKey',
        'ParentDisplayName','ParentKeyName','ReleaseType'
    )

    $items = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($t in $targets) {
        $base = $null; $root = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($t.Hive, $t.View)
            $root = $base.OpenSubKey($t.SubKey, $false)
            if (-not $root) { continue }

            foreach ($subName in $root.GetSubKeyNames()) {
                $k = $null
                try {
                    $k = $root.OpenSubKey($subName, $false)
                    if (-not $k) { continue }
                    $displayName = [string](Convert-RegistryValueKindSafe -Key $k -Name 'DisplayName')
                    if ([string]::IsNullOrWhiteSpace($displayName)) { continue }

                    $o = [ordered]@{}
                    foreach ($n in $propertyNames) { $o[$n] = Convert-RegistryValueKindSafe -Key $k -Name $n }
                    $o['PSChildName'] = $subName
                    $o['RegistryHive'] = $t.HiveName
                    $o['RegistryView'] = $t.ViewName
                    $o['RegistryPath'] = "$($t.HiveName):\$($t.SubKey)\$subName"

                    $dedupe = "$($t.HiveName)|$($t.ViewName)|$subName"
                    if ($seen.Add($dedupe)) { $items.Add([pscustomobject]$o) }
                } catch {} finally { if ($k) { $k.Dispose() } }
            }
        } catch {} finally {
            if ($root) { $root.Dispose() }
            if ($base) { $base.Dispose() }
        }
    }
    return @($items | Sort-Object DisplayName, DisplayVersion, RegistryView)
}

function Test-ProgramSearchMatch {
    param($Program, [string]$Filter)
    if ([string]::IsNullOrWhiteSpace($Filter)) { return $true }

    # Token-based AND matching. "microstation 2026" matches an entry as long as
    # every meaningful token occurs somewhere in the ARP metadata.
    $haystack = @(
        [string]$Program.DisplayName,[string]$Program.DisplayVersion,[string]$Program.Publisher,
        [string]$Program.UninstallString,[string]$Program.QuietUninstallString,[string]$Program.InstallLocation,
        [string]$Program.PSChildName,[string]$Program.BundleCachePath
    ) -join ' '

    $tokens = @($Filter -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($token in $tokens) {
        if ($haystack -notmatch [regex]::Escape($token)) { return $false }
    }
    return $true
}

function Get-InstalledPrograms {
    param([string]$Filter)
    $all = @(Get-InstalledProgramsNative)
    if ([string]::IsNullOrWhiteSpace($Filter)) { return $all }
    return @($all | Where-Object { Test-ProgramSearchMatch -Program $_ -Filter $Filter })
}

function Get-InstallerFamily {
    param($Program, [string]$CommandLine)

    $productCode = Get-ProductCodeFromEntry $Program
    if (($Program.WindowsInstaller -eq 1) -or $productCode -or ($CommandLine -match '(?i)msiexec')) { return 'Windows Installer (MSI)' }

    $parts = Split-CommandLine $CommandLine
    $exe = $parts.Exe
    $meta = Get-FileMetadata $exe
    $name = if ($exe) { [IO.Path]::GetFileName($exe) } else { '' }
    $combined = @($name,$Program.DisplayName,$Program.Publisher,$meta.CompanyName,$meta.ProductName,$meta.FileDescription,$meta.OriginalFilename) -join ' '

    if ($name -match '(?i)^unins\d*\.exe$') { return 'Inno Setup' }
    if ($combined -match '(?i)Nullsoft|NSIS') { return 'NSIS' }
    if ($combined -match '(?i)InstallShield') { return 'InstallShield' }
    if ($combined -match '(?i)Advanced Installer') { return 'Advanced Installer' }
    if ($combined -match '(?i)Squirrel') { return 'Squirrel' }
    if ($combined -match '(?i)WiX|Burn' -or ($exe -and $exe -match '(?i)\\Package Cache\\')) { return 'Bootstrapper / Bundle (possible WiX Burn)' }
    if ($combined -match '(?i)Bentley|MicroStation') { return 'Bentley bootstrapper' }

    return 'Unknown EXE bootstrapper'
}

function New-AnalysisResult {
    param(
        [string]$Command,
        [string]$Confidence,
        [string]$Source,
        [string]$Installer,
        [string[]]$Evidence,
        [string[]]$Warnings
    )
    [pscustomobject]@{
        Command    = $Command
        Confidence = $Confidence
        Source     = $Source
        Installer  = $Installer
        Evidence   = @($Evidence)
        Warnings   = @($Warnings)
    }
}

function Get-SilentAnalysis {
    param($Program)

    $uninstall = [string]$Program.UninstallString
    $quiet = [string]$Program.QuietUninstallString
    $productCode = Get-ProductCodeFromEntry $Program
    $evidence = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    if ($quiet) {
        $family = Get-InstallerFamily -Program $Program -CommandLine $quiet
        $evidence.Add('QuietUninstallString is explicitly registered by the application/vendor.')
        if (-not (Test-CommandHasSilentSwitch $quiet)) {
            $warnings.Add('The registered QuietUninstallString does not contain a recognizable silent switch; test in a lab before deployment.')
        }
        return New-AnalysisResult -Command $quiet -Confidence 'VERIFIED / HIGHEST' -Source 'Registry: QuietUninstallString' -Installer $family -Evidence $evidence -Warnings $warnings
    }

    if ($productCode -and (($Program.WindowsInstaller -eq 1) -or ($uninstall -match '(?i)msiexec'))) {
        $cmd = "msiexec.exe /x $productCode /qn /norestart"
        $evidence.Add("MSI ProductCode detected: $productCode")
        $evidence.Add('Uses documented Windows Installer uninstall and quiet UI switches.')
        return New-AnalysisResult -Command $cmd -Confidence 'VERIFIED / HIGH' -Source 'MSI ProductCode' -Installer 'Windows Installer (MSI)' -Evidence $evidence -Warnings $warnings
    }

    if (-not $uninstall) {
        if ($Program.NoRemove -eq 1) { $warnings.Add('NoRemove=1 is set. The application intentionally suppresses normal ARP removal.') }
        return New-AnalysisResult -Command '' -Confidence 'NONE' -Source 'No uninstall command registered' -Installer 'Unknown' -Evidence $evidence -Warnings $warnings
    }

    $parts = Split-CommandLine $uninstall
    $exe = $parts.Exe
    $args = $parts.Arguments
    $family = Get-InstallerFamily -Program $Program -CommandLine $uninstall
    $exeName = if ($exe) { [IO.Path]::GetFileName($exe) } else { '' }
    $meta = Get-FileMetadata $exe

    if ($exe) {
        $expanded = Expand-CommandPath $exe
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            $evidence.Add("Registered executable exists: $expanded")
        } else {
            $warnings.Add("Registered executable was not found on disk: $expanded")
        }
    }

    # Bentley / MicroStation: apply the vendor rule only when the selected product itself
    # is MicroStation. Publisher="Bentley" alone is NOT enough (CONNECTION Client,
    # licensing components and other Bentley products share the same publisher).
    $microStationSignal = (
        ([string]$Program.DisplayName -match '(?i)\bMicroStation\b') -or
        ($meta -and (([string]$meta.ProductName -match '(?i)\bMicroStation\b') -or ([string]$meta.FileDescription -match '(?i)\bMicroStation\b')))
    )
    if ($microStationSignal -and $exe) {
        $cmd = '"' + (Expand-CommandPath $exe) + '" -Uninstall -Quiet'
        $evidence.Add('MicroStation identity detected from the selected ARP entry or executable metadata.')
        if ($exe -match '(?i)\\ProgramData\\Package Cache\\') { $evidence.Add('Bootstrapper is located in Windows Package Cache.') }
        $evidence.Add('MicroStation vendor uninstall pattern: -Uninstall -Quiet.')
        return New-AnalysisResult -Command $cmd -Confidence 'HIGH / PRODUCT MATCH' -Source 'MicroStation product rule + registered bootstrapper' -Installer 'Bentley MicroStation bootstrapper' -Evidence $evidence -Warnings $warnings
    }

    if (Test-CommandHasSilentSwitch $uninstall) {
        $evidence.Add('The registered UninstallString already contains a recognizable silent switch.')
        return New-AnalysisResult -Command $uninstall -Confidence 'HIGH' -Source 'Registry: UninstallString already appears silent' -Installer $family -Evidence $evidence -Warnings $warnings
    }

    if ($family -eq 'Inno Setup' -and $exe) {
        $cmd = '"' + (Expand-CommandPath $exe) + '" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
        $evidence.Add('unins*.exe naming strongly matches the Inno Setup uninstaller.')
        $warnings.Add('Installer family is inferred. Validate exit code and application removal in a test device.')
        return New-AnalysisResult -Command $cmd -Confidence 'PROBABLE' -Source 'Inno Setup signature' -Installer $family -Evidence $evidence -Warnings $warnings
    }

    if ($family -eq 'NSIS' -and $exe) {
        $cmd = '"' + (Expand-CommandPath $exe) + '" /S'
        $evidence.Add('Executable metadata indicates NSIS/Nullsoft.')
        $warnings.Add('NSIS /S is case-sensitive for many packages and vendor customization can alter behavior. Test before SCCM deployment.')
        return New-AnalysisResult -Command $cmd -Confidence 'PROBABLE' -Source 'NSIS metadata signature' -Installer $family -Evidence $evidence -Warnings $warnings
    }

    if ($family -eq 'Squirrel' -and $exe) {
        $cmd = '"' + (Expand-CommandPath $exe) + '" --uninstall -s'
        $warnings.Add('Squirrel command-line behavior varies by application release. Treat this as a candidate only.')
        return New-AnalysisResult -Command $cmd -Confidence 'CANDIDATE' -Source 'Squirrel signature' -Installer $family -Evidence $evidence -Warnings $warnings
    }

    # Preserve vendor uninstall command rather than inventing /S.
    $evidence.Add('A vendor UninstallString exists, but no reliable silent switch could be proven.')
    $warnings.Add('No silent switch was appended automatically. This is intentional to avoid unsafe /S guessing.')
    return New-AnalysisResult -Command $uninstall -Confidence 'UNVERIFIED' -Source 'Registry: UninstallString only' -Installer $family -Evidence $evidence -Warnings $warnings
}

function Get-MeaningfulTokens {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $stop = @(
        'edition','software','systems','system','company','limited','incorporated','corporation',
        'client','application','applications','windows','microsoft','program','setup','installer',
        'x64','x86','connect','version','update','runtime','component','components'
    )

    $tokens = @()
    foreach ($t in ($Text -split '[^A-Za-z0-9]+')) {
        $x = $t.Trim().ToLowerInvariant()
        if ($x.Length -lt 4) { continue }
        if ($stop -contains $x) { continue }
        if ($x -match '^\d+$') { continue }
        $tokens += $x
    }
    return @($tokens | Select-Object -Unique)
}

function Get-AuthenticodeSummary {
    param([string]$Path)

    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        return [pscustomobject]@{
            Status  = [string]$sig.Status
            Subject = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' }
        }
    } catch {
        return [pscustomobject]@{ Status='Unknown'; Subject='' }
    }
}

function Get-ProductAffinity {
    param($Program, [System.IO.FileInfo]$File)

    $meta = $File.VersionInfo
    $selectedName = [string]$Program.DisplayName
    $selectedPublisher = [string]$Program.Publisher
    $candidateText = @(
        $File.Name, $File.FullName, $meta.CompanyName, $meta.ProductName,
        $meta.FileDescription, $meta.OriginalFilename
    ) -join ' '

    $productTokens = @(Get-MeaningfulTokens $selectedName)
    $vendorTokens  = @(Get-MeaningfulTokens $selectedPublisher)
    $score = 0
    $reasons = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    # Exact path from ARP is decisive evidence.
    $knownExe = $null
    if ($Program.UninstallString) { $knownExe = (Split-CommandLine $Program.UninstallString).Exe }
    if ($knownExe -and [string]::Equals((Expand-CommandPath $knownExe), $File.FullName, [StringComparison]::OrdinalIgnoreCase)) {
        $score += 100
        $reasons.Add('Exact executable path referenced by UninstallString')
    }

    # Product-name evidence carries much more weight than manufacturer evidence.
    $matchedProductTokens = 0
    foreach ($t in $productTokens) {
        if ($candidateText -match [regex]::Escape($t)) {
            $matchedProductTokens++
            $score += 22
            $reasons.Add("Product token matched: $t")
        }
    }

    if ($productTokens.Count -gt 0) {
        $ratio = $matchedProductTokens / [double]$productTokens.Count
        if ($ratio -ge 0.75) { $score += 25; $reasons.Add('Strong selected-product name correlation') }
        elseif ($ratio -eq 0) { $score -= 35; $warnings.Add('No selected-product token appears in this candidate') }
    }

    $vendorMatched = $false
    foreach ($t in $vendorTokens) {
        if ($candidateText -match [regex]::Escape($t)) { $vendorMatched = $true; break }
    }
    if ($vendorMatched) { $score += 10; $reasons.Add('Publisher/vendor metadata matched') }

    if ($File.Name -match '(?i)^Setup_.*\.exe$|^setup\.exe$|bootstrap|bundle') {
        $score += 8
        $reasons.Add('Bootstrapper-like filename')
    }

    # Bentley-specific false-positive protection discovered during MicroStation testing.
    if ($selectedName -match '(?i)\bMicroStation\b') {
        if ($candidateText -match '(?i)\bMicroStation\b') {
            $score += 45
            $reasons.Add('Explicit MicroStation identity')
        }
        else {
            $score -= 55
            $warnings.Add('Selected product is MicroStation but candidate metadata does not identify MicroStation')
        }

        if ($candidateText -match '(?i)CONNECTION\s*Client|CONNECTIONClient') {
            $score -= 80
            $warnings.Add('Bentley CONNECTION Client is a related prerequisite, not the MicroStation uninstaller')
        }
        if ($candidateText -match '(?i)Licens|License') {
            $score -= 50
            $warnings.Add('Bentley licensing component detected; not treated as the main product')
        }
    }

    # Generic same-vendor/different-product protection.
    $candidateProduct = [string]$meta.ProductName
    if ($vendorMatched -and $matchedProductTokens -eq 0 -and $candidateProduct) {
        $score -= 20
        $warnings.Add("Same vendor but different/uncorrelated product: $candidateProduct")
    }

    $score = [Math]::Max(0, [Math]::Min(100, $score))
    $confidence = if ($score -ge 90) { 'VERY HIGH' }
                  elseif ($score -ge 75) { 'HIGH' }
                  elseif ($score -ge 55) { 'MEDIUM' }
                  elseif ($score -ge 35) { 'LOW' }
                  else { 'REJECT / RELATED COMPONENT' }

    return [pscustomobject]@{
        Affinity   = $score
        Confidence = $confidence
        Reasons    = @($reasons)
        Warnings   = @($warnings)
    }
}

function Get-PackageCacheCandidates {
    param($Program, [int]$MaxResults = 40)

    $root = Join-Path $env:ProgramData 'Package Cache'
    if (-not (Test-Path -LiteralPath $root)) { return @() }

    $results = New-Object System.Collections.Generic.List[object]
    try {
        $executables = Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.exe' -ErrorAction SilentlyContinue
        foreach ($f in $executables) {
            $aff = Get-ProductAffinity -Program $Program -File $f

            # Keep low-confidence related components visible for forensic context,
            # but they sort below actual product matches.
            $meta = $f.VersionInfo
            $sig = Get-AuthenticodeSummary -Path $f.FullName

            $sameVendor = $false
            if (-not [string]::IsNullOrWhiteSpace([string]$Program.Publisher)) {
                $sameVendor = ([string]$meta.CompanyName -match ('(?i)' + [regex]::Escape([string]$Program.Publisher)))
            }

            if ($aff.Affinity -gt 0 -or $sameVendor) {
                $results.Add([pscustomobject]@{
                    Affinity     = $aff.Affinity
                    Confidence   = $aff.Confidence
                    Path         = $f.FullName
                    CompanyName  = $meta.CompanyName
                    ProductName  = $meta.ProductName
                    Description  = $meta.FileDescription
                    Version      = $meta.FileVersion
                    Signature    = $sig.Status
                    Signer       = $sig.Subject
                    Reasons      = ($aff.Reasons -join '; ')
                    Warnings     = ($aff.Warnings -join '; ')
                })
            }
        }
    } catch {}

    $results |
        Sort-Object -Property @{Expression='Affinity';Descending=$true}, Path |
        Select-Object -First $MaxResults
}

function Search-InstallFolder {
    param([string]$FolderPath)

    if (-not $FolderPath -or -not (Test-Path -LiteralPath $FolderPath)) { return @() }

    $patterns = @('unins*.exe','uninstall*.exe','uninstaller*.exe','setup*.exe','install*.exe','update*.exe','*bootstrap*.exe','*bundle*.exe')
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $patterns) {
        try {
            foreach ($f in (Get-ChildItem -LiteralPath $FolderPath -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue)) {
                if (-not $found.Contains($f.FullName)) { $found.Add($f.FullName) }
            }
        } catch {}
    }
    $found | Sort-Object
}

function Get-SccmDetectionHint {
    param($Program)
    $code = Get-ProductCodeFromEntry $Program
    if ($code) {
        return "MSI detection: Windows Installer product code $code"
    }
    if ($Program.RegistryPath) {
        $reg = $Program.RegistryPath -replace '^HKEY_LOCAL_MACHINE','HKLM:' -replace '^HKEY_CURRENT_USER','HKCU:'
        return "Registry detection candidate: $reg ; DisplayVersion = $($Program.DisplayVersion)"
    }
    return 'No reliable detection hint available.'
}

# -----------------------------------------------------------------------------
# GUI
# -----------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Application Installer Analyzer v2.2 - Native Registry Analyzer'
$form.Size = New-Object System.Drawing.Size(1040, 760)
$form.MinimumSize = New-Object System.Drawing.Size(900, 650)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = 'Software name (or part of the name):'
$lblSearch.Location = New-Object System.Drawing.Point(14, 15)
$lblSearch.AutoSize = $true
$form.Controls.Add($lblSearch)

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(17, 38)
$txtSearch.Size = New-Object System.Drawing.Size(460, 25)
$txtSearch.Anchor = 'Top,Left,Right'
$form.Controls.Add($txtSearch)

$btnSearch = New-Object System.Windows.Forms.Button
$btnSearch.Text = 'Search Registry'
$btnSearch.Location = New-Object System.Drawing.Point(490, 37)
$btnSearch.Size = New-Object System.Drawing.Size(120, 28)
$btnSearch.Anchor = 'Top,Right'
$form.Controls.Add($btnSearch)


$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Text = 'Enumerate All'
$btnAll.Location = New-Object System.Drawing.Point(618, 37)
$btnAll.Size = New-Object System.Drawing.Size(122, 28)
$btnAll.Anchor = 'Top,Right'
$form.Controls.Add($btnAll)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = 'Search Folder...'
$btnFolder.Location = New-Object System.Drawing.Point(748, 37)
$btnFolder.Size = New-Object System.Drawing.Size(120, 28)
$btnFolder.Anchor = 'Top,Right'
$form.Controls.Add($btnFolder)

$btnCache = New-Object System.Windows.Forms.Button
$btnCache.Text = 'Package Cache'
$btnCache.Location = New-Object System.Drawing.Point(878, 37)
$btnCache.Size = New-Object System.Drawing.Size(125, 28)
$btnCache.Anchor = 'Top,Right'
$form.Controls.Add($btnCache)

$lstResults = New-Object System.Windows.Forms.ListBox
$lstResults.Location = New-Object System.Drawing.Point(17, 76)
$lstResults.Size = New-Object System.Drawing.Size(994, 125)
$lstResults.Anchor = 'Top,Left,Right'
$form.Controls.Add($lstResults)

$grpAnalysis = New-Object System.Windows.Forms.GroupBox
$grpAnalysis.Text = 'Analysis'
$grpAnalysis.Location = New-Object System.Drawing.Point(17, 210)
$grpAnalysis.Size = New-Object System.Drawing.Size(994, 365)
$grpAnalysis.Anchor = 'Top,Left,Right'
$form.Controls.Add($grpAnalysis)

$txtDetails = New-Object System.Windows.Forms.TextBox
$txtDetails.Location = New-Object System.Drawing.Point(12, 24)
$txtDetails.Size = New-Object System.Drawing.Size(970, 255)
$txtDetails.Multiline = $true
$txtDetails.ScrollBars = 'Both'
$txtDetails.WordWrap = $false
$txtDetails.ReadOnly = $true
$txtDetails.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtDetails.Anchor = 'Top,Bottom,Left,Right'
$grpAnalysis.Controls.Add($txtDetails)

$lblCommand = New-Object System.Windows.Forms.Label
$lblCommand.Text = 'Recommended / discovered command:'
$lblCommand.Location = New-Object System.Drawing.Point(12, 290)
$lblCommand.AutoSize = $true
$grpAnalysis.Controls.Add($lblCommand)

$txtSilent = New-Object System.Windows.Forms.TextBox
$txtSilent.Location = New-Object System.Drawing.Point(12, 313)
$txtSilent.Size = New-Object System.Drawing.Size(820, 26)
$txtSilent.ReadOnly = $true
$txtSilent.Anchor = 'Bottom,Left,Right'
$grpAnalysis.Controls.Add($txtSilent)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = 'Copy Command'
$btnCopy.Location = New-Object System.Drawing.Point(842, 311)
$btnCopy.Size = New-Object System.Drawing.Size(140, 29)
$btnCopy.Anchor = 'Bottom,Right'
$grpAnalysis.Controls.Add($btnCopy)

$grpCache = New-Object System.Windows.Forms.GroupBox
$grpCache.Text = 'Package Cache / product-correlated bootstrapper candidates (double-click for evidence)'
$grpCache.Location = New-Object System.Drawing.Point(17, 585)
$grpCache.Size = New-Object System.Drawing.Size(994, 105)
$grpCache.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($grpCache)

$lstCache = New-Object System.Windows.Forms.ListBox
$lstCache.Location = New-Object System.Drawing.Point(12, 23)
$lstCache.Size = New-Object System.Drawing.Size(970, 68)
$lstCache.HorizontalScrollbar = $true
$lstCache.Anchor = 'Top,Bottom,Left,Right'
$grpCache.Controls.Add($lstCache)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Spring = $true
$statusLabel.TextAlign = 'MiddleLeft'
$statusLabel.Text = 'Ready.'
$statusStrip.Items.Add($statusLabel) | Out-Null
$form.Controls.Add($statusStrip)

$script:currentResults = @{}
$script:currentProgram = $null
$script:cacheResults = @{}

function Show-ProgramAnalysis {
    param($Program)

    $script:currentProgram = $Program
    $analysis = Get-SilentAnalysis -Program $Program
    $code = Get-ProductCodeFromEntry $Program
    $parts = Split-CommandLine $Program.UninstallString
    $meta = Get-FileMetadata $parts.Exe

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Name             : $($Program.DisplayName)")
    $lines.Add("Version          : $($Program.DisplayVersion)")
    $lines.Add("Publisher        : $($Program.Publisher)")
    $lines.Add("Registry         : $($Program.RegistryHive) / $($Program.RegistryView)")
    $lines.Add("Registry path    : $($Program.RegistryPath)")
    $lines.Add("Install location : $($Program.InstallLocation)")
    $lines.Add("Install source   : $($Program.InstallSource)")
    $lines.Add("Display icon     : $($Program.DisplayIcon)")
    $lines.Add("WindowsInstaller : $($Program.WindowsInstaller)")
    $lines.Add("SystemComponent  : $($Program.SystemComponent)")
    $lines.Add("NoRemove         : $($Program.NoRemove)")
    $lines.Add("ProductCode      : $code")
    $lines.Add('')
    $lines.Add("UninstallString       : $($Program.UninstallString)")
    $lines.Add("QuietUninstallString  : $($Program.QuietUninstallString)")
    $lines.Add("ModifyPath            : $($Program.ModifyPath)")
    $lines.Add("RepairPath            : $($Program.RepairPath)")
    $lines.Add("BundleCachePath       : $($Program.BundleCachePath)")
    $lines.Add("BundleProviderKey     : $($Program.BundleProviderKey)")
    $lines.Add('')
    $lines.Add("Installer family : $($analysis.Installer)")
    $lines.Add("Confidence       : $($analysis.Confidence)")
    $lines.Add("Source           : $($analysis.Source)")
    $lines.Add("SCCM hint        : $(Get-SccmDetectionHint -Program $Program)")

    if ($meta) {
        $lines.Add('')
        $lines.Add('Executable metadata:')
        $lines.Add("  Path            : $($meta.Path)")
        $lines.Add("  Company         : $($meta.CompanyName)")
        $lines.Add("  Product         : $($meta.ProductName)")
        $lines.Add("  Description     : $($meta.FileDescription)")
        $lines.Add("  FileVersion     : $($meta.FileVersion)")
    }

    if ($analysis.Evidence.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Evidence:')
        foreach ($e in $analysis.Evidence) { $lines.Add("  + $e") }
    }

    if ($analysis.Warnings.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Warnings:')
        foreach ($w in $analysis.Warnings) { $lines.Add("  ! $w") }
    }

    $lines.Add('')
    $lines.Add('Safety: this tool never executes the uninstall command automatically.')

    $txtDetails.Text = $lines -join "`r`n"
    $txtSilent.Text = $analysis.Command
    $statusLabel.Text = "Analyzed: $($Program.DisplayName) | Confidence: $($analysis.Confidence)"
}

function Load-ProgramList {
    param([string]$Filter)

    $lstResults.Items.Clear(); $txtDetails.Clear(); $txtSilent.Clear(); $lstCache.Items.Clear()
    $script:currentResults.Clear(); $script:cacheResults.Clear(); $script:currentProgram = $null

    $statusLabel.Text = 'Reading native 64-bit / 32-bit uninstall registrations...'; $form.Refresh()
    $programs = @(Get-InstalledPrograms -Filter $Filter)

    if ($programs.Count -eq 0) {
        $statusLabel.Text = if ($Filter) { "No registration matched '$Filter'." } else { 'No ARP registrations were enumerated.' }
        [System.Windows.Forms.MessageBox]::Show(
            "No matching ARP registration was found in the native 64-bit, native 32-bit, or current-user uninstall registry views.`r`n`r`nUse Enumerate All to verify what Windows exposes to the tool.",
            'Application Installer Analyzer v2.2','OK','Information') | Out-Null
        return
    }

    $i = 0
    foreach ($p in $programs) {
        $i++
        $label = "[$i] $($p.DisplayName)"
        if ($p.DisplayVersion) { $label += "  v$($p.DisplayVersion)" }
        if ($p.Publisher) { $label += "  | $($p.Publisher)" }
        $label += "  [$($p.RegistryHive) $($p.RegistryView)]"
        $lstResults.Items.Add($label) | Out-Null
        $script:currentResults[$label] = $p
    }
    $statusLabel.Text = "$($programs.Count) registration(s) enumerated. Select one to analyze."
}

$btnSearch.Add_Click({
    $term = $txtSearch.Text.Trim()
    if (-not $term) { $statusLabel.Text = 'Type a software name or use Enumerate All.'; return }
    Load-ProgramList -Filter $term
})

$btnAll.Add_Click({
    Load-ProgramList -Filter ''
})

$lstResults.Add_SelectedIndexChanged({
    if ($null -eq $lstResults.SelectedItem) { return }
    $p = $script:currentResults[[string]$lstResults.SelectedItem]
    if ($p) { Show-ProgramAnalysis -Program $p }
})

$btnFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select an application or installer/cache folder to inspect'
    if ($dlg.ShowDialog() -ne 'OK') { return }

    $statusLabel.Text = 'Scanning selected folder for installer/uninstaller executables...'; $form.Refresh()
    $found = @(Search-InstallFolder -FolderPath $dlg.SelectedPath)

    $lstResults.Items.Clear(); $script:currentResults.Clear()
    if ($found.Count -eq 0) {
        $statusLabel.Text = 'No likely installer/uninstaller executable found.'
        return
    }

    $i = 0
    foreach ($exe in $found) {
        $i++
        $meta = Get-FileMetadata $exe
        $label = "[$i] $exe"
        $lstResults.Items.Add($label) | Out-Null
        $script:currentResults[$label] = [pscustomobject]@{
            DisplayName          = if ($meta.ProductName) { $meta.ProductName } else { [IO.Path]::GetFileName($exe) }
            DisplayVersion       = $meta.ProductVersion
            Publisher            = $meta.CompanyName
            InstallLocation      = $dlg.SelectedPath
            InstallSource        = $null
            DisplayIcon          = $null
            WindowsInstaller     = 0
            SystemComponent      = 0
            NoRemove             = 0
            ModifyPath           = $null
            UninstallString      = '"' + $exe + '"'
            QuietUninstallString = $null
            PSChildName          = $null
            RegistryHive         = 'Folder scan'
            RegistryView         = '-'
            RegistryPath         = '-'
        }
    }
    $statusLabel.Text = "$($found.Count) candidate executable(s) found."
})

$btnCache.Add_Click({
    if (-not $script:currentProgram) {
        $term = $txtSearch.Text.Trim()
        if (-not $term) {
            [System.Windows.Forms.MessageBox]::Show('Search and select a software first. Package Cache scoring uses the selected product metadata.','Application Installer Analyzer v2.2','OK','Information') | Out-Null
            return
        }
        $programs = @(Get-InstalledPrograms -Filter $term)
        if ($programs.Count -gt 0) { $script:currentProgram = $programs[0] }
        else {
            $script:currentProgram = [pscustomobject]@{ DisplayName=$term; Publisher=''; UninstallString=''; QuietUninstallString=''; PSChildName=''; WindowsInstaller=0 }
        }
    }

    $lstCache.Items.Clear(); $script:cacheResults.Clear()
    $statusLabel.Text = 'Scanning C:\ProgramData\Package Cache and scoring candidates...'; $form.Refresh()
    $candidates = @(Get-PackageCacheCandidates -Program $script:currentProgram)
    if ($candidates.Count -eq 0) { $statusLabel.Text = 'No relevant Package Cache candidate found.'; return }

    $n = 0
    foreach ($c in $candidates) {
        $n++
        $label = "Affinity $($c.Affinity)% [$($c.Confidence)] | $($c.Path) | $($c.CompanyName) | $($c.ProductName)"
        $lstCache.Items.Add($label) | Out-Null
        $script:cacheResults[$label] = $c
    }
    $statusLabel.Text = "$($candidates.Count) Package Cache candidate(s) found. Highest affinity is most relevant; same-vendor related components are intentionally penalized."
})

$lstCache.Add_DoubleClick({
    if ($null -eq $lstCache.SelectedItem) { return }
    $c = $script:cacheResults[[string]$lstCache.SelectedItem]
    if (-not $c) { return }

    $candidateDetails = @(
        "Package Cache candidate",
        "-----------------------",
        "Affinity   : $($c.Affinity)%",
        "Confidence : $($c.Confidence)",
        "Path       : $($c.Path)",
        "Company    : $($c.CompanyName)",
        "Product    : $($c.ProductName)",
        "Description: $($c.Description)",
        "Version    : $($c.Version)",
        "Signature  : $($c.Signature)",
        "Signer     : $($c.Signer)",
        "Evidence   : $($c.Reasons)",
        "Warnings   : $($c.Warnings)"
    ) -join "`r`n"

    $txtDetails.Text = $txtDetails.Text + "`r`n`r`n" + $candidateDetails

    $selectedIsMicroStation = ($script:currentProgram -and ([string]$script:currentProgram.DisplayName -match '(?i)\bMicroStation\b'))
    $candidateIsMicroStation = (([string]$c.ProductName -match '(?i)\bMicroStation\b') -or ([string]$c.Description -match '(?i)\bMicroStation\b') -or ([string]$c.Path -match '(?i)\bMicroStation\b'))

    if ($selectedIsMicroStation -and $candidateIsMicroStation -and $c.Affinity -ge 75) {
        $txtSilent.Text = '"' + $c.Path + '" -Uninstall -Quiet'
        $statusLabel.Text = 'High-confidence MicroStation cache candidate selected; uninstall pattern prepared.'
    }
    elseif ($c.Confidence -eq 'REJECT / RELATED COMPONENT') {
        $txtSilent.Clear()
        $statusLabel.Text = 'Related component rejected. No uninstall command generated.'
        [System.Windows.Forms.MessageBox]::Show(
            "This executable belongs to the same ecosystem/vendor but does not correlate strongly enough with the selected product.`r`n`r`nNo uninstall command was generated.",
            'Candidate rejected','OK','Warning') | Out-Null
    }
    else {
        $txtSilent.Text = '"' + $c.Path + '"'
        $statusLabel.Text = 'Candidate selected without guessed switches. Review evidence before use.'
    }
})

$btnCopy.Add_Click({
    if ($txtSilent.Text) {
        [System.Windows.Forms.Clipboard]::SetText($txtSilent.Text)
        $statusLabel.Text = 'Command copied to clipboard.'
    }
})

$txtSearch.Add_KeyDown({
    param($s,$e)
    if ($e.KeyCode -eq 'Enter') { $btnSearch.PerformClick(); $e.SuppressKeyPress = $true }
})

$form.Add_Shown({
    $form.Activate()
    if (-not (Test-IsAdministrator)) {
        $statusLabel.Text = 'Running non-elevated. HKCU/HKLM reads usually work, but elevation is recommended for packaging analysis.'
    }
})

[void]$form.ShowDialog()
