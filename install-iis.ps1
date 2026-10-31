#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install, update or roll back the Brotli-IIS "br" compression scheme on this IIS server.

.DESCRIPTION
    Deploys a prebuilt brotli.dll (no build on the target). Runs on Windows PowerShell 5.1
    and PowerShell 7. IIS configuration changes go through appcmd.exe; the DLL copy, state
    file and service restart are the only other changes. -WhatIf lists the changes and makes
    none; -Confirm asks once for the whole change set.

    Install:
      1. Preflight: 64-bit OS, IIS present, static + dynamic compression modules present,
         CPU reports AVX2 (the DLL is built with /arch:AVX2), DLL SHA-256 = -ExpectedSha256.
      2. appcmd backup of applicationHost.config, named brotli-iis-<timestamp>.
      3. Write a state file next to the DLLs recording the previous br scheme (all its
         attributes and its position), the two -ProxyFriendly attributes and the scheme
         order, for -Rollback. It is written before any configuration change; if an install
         stops midway, the next install keeps that baseline.
      4. Copy the DLL to %ProgramFiles%\IIS\IIS Compression\brotli-<major.minor.patch>.dll
         (a versioned name, because w3wp.exe keeps a loaded DLL locked; the previous file
         stays in place for rollback).
      5. Register or repoint the "br" scheme as the FIRST scheme, so it precedes gzip/deflate
         (IIS 10 1803+ uses registration order to break ties between equal q-values). An
         existing br scheme keeps its other attributes (doStaticCompression, ...).
      6. Optional -ProxyFriendly: noCompressionForProxies=false and
         staticCompressionIgnoreHitFrequency=true, so requests arriving through a CDN or
         proxy (Via header) are compressed, and static files from the first hit.
    A scheme dll or level change takes effect only after a WWW service restart (Microsoft
    scheme reference); -RestartWww does it, otherwise the commands are printed.

    Rollback: restores the "br" scheme (attributes and position, or removes it if the install
    added it) and the two -ProxyFriendly attributes recorded by the last install that changed
    something, then checks the scheme order; the state file is removed only when it matches.
    Restoring a middle position moves the schemes that followed br back to the end, in their
    previous order, with their current attributes. Other configuration is left alone. The full
    applicationHost.config backup is also kept; its restore command is printed.

.EXAMPLE
    .\install-iis.ps1 -DllPath .\brotli.dll -ExpectedSha256 <sha256 from SHA256SUMS> -ProxyFriendly -WhatIf
.EXAMPLE
    .\install-iis.ps1 -DllPath .\brotli.dll -ExpectedSha256 <sha256> -ProxyFriendly -RestartWww -VerifyUrl https://www.example.com/some.css
.EXAMPLE
    .\install-iis.ps1 -Rollback -RestartWww
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Install')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Install')]
    [string]$DllPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Install')]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ExpectedSha256,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateRange(0, 11)]
    [int]$DynamicLevel = 4,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateRange(0, 11)]
    [int]$StaticLevel = 10,

    [Parameter(ParameterSetName = 'Install')]
    [switch]$ProxyFriendly,

    [Parameter(Mandatory = $true, ParameterSetName = 'Rollback')]
    [switch]$Rollback,

    [switch]$RestartWww,

    [Parameter(ParameterSetName = 'Install')]
    [string]$VerifyUrl
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Section    = 'system.webServer/httpCompression'
$AppCmd     = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
$TargetDir  = Join-Path $env:ProgramFiles 'IIS\IIS Compression'
$StateFile  = Join-Path $TargetDir 'brotli-iis-state.json'
$ProxyAttrs = @('noCompressionForProxies', 'staticCompressionIgnoreHitFrequency')
$applied    = $false   # set once a confirmed change set has been applied in full

# Native exits do not throw under $ErrorActionPreference = 'Stop'; every appcmd call goes
# through this function, which does.
function Invoke-AppCmd {
    param([string[]]$Arguments)
    $out = & $AppCmd @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "appcmd $($Arguments -join ' ') failed (exit $LASTEXITCODE): $($out -join ' ')"
    }
    return $out
}

function Get-CompressionConfig {
    [xml]$xml = (Invoke-AppCmd @('list', 'config', "-section:$Section", '/xml', '/config:*')) -join "`n"
    $node = $xml.SelectSingleNode('/appcmd/CONFIG/system.webServer-httpCompression')
    if ($null -eq $node) { throw "Could not read $Section from appcmd output." }
    # /config:* lists every attribute, defaults included, so Attrs is the scheme's full state.
    $schemes = @()
    $nodes = @($node.SelectNodes('scheme'))
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        $attrs = [ordered]@{}
        foreach ($a in $nodes[$i].Attributes) { $attrs[$a.Name] = $a.Value }
        $position = 'middle'
        if ($i -eq 0) { $position = 'start' } elseif ($i -eq $nodes.Count - 1) { $position = 'end' }
        $schemes += [pscustomobject]@{ Name = $attrs['name']; Attrs = $attrs; Position = $position }
    }
    $proxy = [ordered]@{}
    foreach ($a in $ProxyAttrs) { $proxy[$a] = $node.GetAttribute($a) }
    return [pscustomobject]@{ Schemes = $schemes; Proxy = $proxy }
}

function Get-BrScheme([object]$Config) {
    return @($Config.Schemes | Where-Object { $_.Name -eq 'br' }) | Select-Object -First 1
}

function Show-Schemes([object]$Config) {
    $i = 0
    foreach ($s in $Config.Schemes) {
        $i++
        Write-Host ("  {0}. {1,-8} {2}  dynamic={3} static={4}" -f $i, $s.Name, $s.Attrs['dll'], $s.Attrs['dynamicCompressionLevel'], $s.Attrs['staticCompressionLevel'])
    }
}

# Makes the br scheme carry exactly $Attrs at $Position ('start' or 'end', the two positions
# appcmd names). Already at that position: every attribute is set in place in one appcmd
# commit. Otherwise it is removed and re-added there: two commits, so for a moment the server
# has no br scheme (running workers keep their loaded DLL until the WWW service restarts).
function Set-BrScheme([System.Collections.IDictionary]$Attrs, [string]$Position, [object]$Current) {
    foreach ($k in $Attrs.Keys) {
        if ("$($Attrs[$k])".Contains("'")) { throw "Scheme attribute $k contains a single quote, which appcmd cannot take: $($Attrs[$k])" }
    }
    if ($null -ne $Current -and $Current.Position -eq $Position) {
        $sets = @($Attrs.Keys | Where-Object { $_ -ne 'name' } | ForEach-Object { "/[name='br'].${_}:$($Attrs[$_])" })
        Invoke-AppCmd (@('set', 'config', "-section:$Section") + $sets + @('/commit:apphost')) | Out-Null
        return
    }
    if ($null -ne $Current) {
        Invoke-AppCmd @('set', 'config', "-section:$Section", "/-[name='br']", '/commit:apphost') | Out-Null
    }
    $list = (@($Attrs.Keys) | ForEach-Object { "$_='$($Attrs[$_])'" }) -join ','
    Invoke-AppCmd @('set', 'config', "-section:$Section", "/+[@$Position,$list]", '/commit:apphost') | Out-Null
}

function Write-State([hashtable]$State) {
    # -Confirm:$false here and below: these run only inside an already-approved change set,
    # and a second, nested prompt could otherwise skip a step the next ones depend on.
    New-Item -ItemType Directory -Force -Path $TargetDir -Confirm:$false | Out-Null
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8 -Confirm:$false
}

$Curl = Join-Path $env:windir 'System32\curl.exe'

# Returns $true when the service was restarted (not under -WhatIf or a declined -Confirm).
function Restart-Www {
    if ($PSCmdlet.ShouldProcess('W3SVC', 'Restart the World Wide Web Publishing Service (brief interruption for every site)')) {
        Restart-Service -Name W3SVC -Force -Confirm:$false
        if ((Get-Service -Name W3SVC).Status -ne 'Running') { throw 'W3SVC is not running after the restart.' }
        Write-Host 'W3SVC restarted.'
        return $true
    }
    return $false
}

function Test-BrResponse([string]$Url) {
    $headers = & $Curl -sS -o NUL -D - --max-time 30 -H 'Accept-Encoding: br' $Url 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Verification request failed (curl exit $LASTEXITCODE): $($headers -join ' ')" }
    $enc = @($headers | Where-Object { $_ -match '^\s*Content-Encoding\s*:\s*(\S+)' } | ForEach-Object { $Matches[1] }) | Select-Object -Last 1
    if ($enc -eq 'br') {
        Write-Host "Verified: $Url answered Content-Encoding: br."
    } else {
        throw "Verification failed: $Url answered Content-Encoding '$enc' to a br-only request (expect br for a compressible type above minFileSizeForComp)."
    }
}

function Write-RestartNote {
    Write-Host ''
    Write-Host 'The new scheme takes effect after a WWW service restart (a brief interruption for every site):'
    Write-Host '  net stop w3svc /y'
    Write-Host '  net start w3svc'
    Write-Host 'or re-run this script with -RestartWww.'
}

# <httpCompression> element attributes apply once the application pools recycle; a WWW
# service restart also does it.
function Write-RecycleNote {
    Write-Host ''
    Write-Host 'The proxy settings take effect when the application pools recycle (or after a WWW service restart):'
    Write-Host '  appcmd list apppool /xml | appcmd recycle apppool /in'
}

# Shared end of install and rollback: restart if asked, otherwise say what activates the
# change; verify only when the running workers reflect the configuration.
function Complete-Activation([bool]$SchemeChanged, [bool]$ProxyChanged) {
    $restarted = $false
    if ($RestartWww) { $restarted = Restart-Www }
    elseif ($SchemeChanged) { Write-RestartNote }
    elseif ($ProxyChanged) { Write-RecycleNote }
    if (-not $VerifyUrl) { return }
    if ($WhatIfPreference) { Write-Host 'Skipping -VerifyUrl under -WhatIf.'; return }
    if (($SchemeChanged -or $ProxyChanged) -and -not $restarted) {
        throw "The change was applied, but -VerifyUrl was not checked: it is not active until the WWW service restarts. Re-run with -RestartWww, or restart and run the script again."
    }
    Test-BrResponse $VerifyUrl
}

# ---------------------------------------------------------------------------- preflight
if ($VerifyUrl -and -not (Test-Path $Curl)) { throw "-VerifyUrl needs $Curl, which is not present." }
if (-not [Environment]::Is64BitOperatingSystem) { throw 'This DLL is x64; the operating system is not 64-bit.' }
if (-not (Test-Path $AppCmd)) { throw "IIS is not installed ($AppCmd not found)." }

[xml]$modulesXml = (Invoke-AppCmd @('list', 'config', '-section:system.webServer/globalModules', '/xml')) -join "`n"
foreach ($m in @('StaticCompressionModule', 'DynamicCompressionModule')) {
    if ($null -eq $modulesXml.SelectSingleNode("//add[@name='$m']")) {
        throw "IIS module $m is not installed. Install the IIS role features Web-Stat-Compression and Web-Dyn-Compression first."
    }
}

# ---------------------------------------------------------------------------- rollback
if ($PSCmdlet.ParameterSetName -eq 'Rollback') {
    if (-not (Test-Path $StateFile)) { throw "No install state found at $StateFile; nothing to roll back." }
    $state  = Get-Content -Raw -Path $StateFile | ConvertFrom-Json
    $config = Get-CompressionConfig
    $br     = Get-BrScheme $config
    Write-Host "Rolling back to the configuration recorded before backup $($state.Backup)."

    $previousAttrs = $null
    if ($state.PreviousBr) {
        $previousAttrs = [ordered]@{}
        foreach ($p in $state.PreviousBr.Attrs.PSObject.Properties) { $previousAttrs[$p.Name] = $p.Value }
    }
    $proxyRestore = @($ProxyAttrs | Where-Object { "$($state.PreviousProxy.$_)" -ne '' -and $state.PreviousProxy.$_ -ne $config.Proxy[$_] })
    $plan = @()
    if ($null -ne $previousAttrs) { $plan += "restore br (dll=$($previousAttrs['dll'])) at its previous position ($($state.PreviousBr.Position))" }
    elseif ($null -ne $br) { $plan += 'remove br (absent before the install)' }
    foreach ($a in $proxyRestore) { $plan += "set $a back to '$($state.PreviousProxy.$a)'" }
    $plan += 'remove the install state file'

    # One confirmation for the whole rollback; the state file goes only after every step succeeded.
    if ($PSCmdlet.ShouldProcess($Section, ($plan -join '; '))) {
        if ($null -ne $previousAttrs) {
            $position = $state.PreviousBr.Position
            if ($position -eq 'middle') { $position = 'end' }
            Set-BrScheme -Attrs $previousAttrs -Position $position -Current $br
            if ($state.PreviousBr.Position -eq 'middle') {
                # appcmd names only @start and @end, so rebuild the middle position: every scheme
                # that followed br is moved back to the end, in its previous order, with all its
                # current attributes.
                $previousOrder = @($state.PreviousOrder)
                $current = Get-CompressionConfig
                foreach ($name in $previousOrder[([array]::IndexOf($previousOrder, 'br') + 1)..($previousOrder.Count - 1)]) {
                    $scheme = @($current.Schemes | Where-Object { $_.Name -eq $name }) | Select-Object -First 1
                    if ($null -eq $scheme) { continue }
                    $list = (@($scheme.Attrs.Keys) | ForEach-Object { "$_='$($scheme.Attrs[$_])'" }) -join ','
                    if (@($scheme.Attrs.Values | Where-Object { "$_".Contains("'") }).Count -gt 0) { throw "Scheme $name has an attribute value with a single quote; restore the order by hand: $($previousOrder -join ', ')" }
                    Invoke-AppCmd @('set', 'config', "-section:$Section", "/-[name='$name']", '/commit:apphost') | Out-Null
                    Invoke-AppCmd @('set', 'config', "-section:$Section", "/+[@end,$list]", '/commit:apphost') | Out-Null
                }
            }
            $now = @((Get-CompressionConfig).Schemes | ForEach-Object { $_.Name })
            $expected = @($state.PreviousOrder | Where-Object { $now -contains $_ })
            $nowKnown = (@($now | Where-Object { $expected -contains $_ })) -join ','
            if ($nowKnown -ne ($expected -join ',')) {
                throw "Scheme order after rollback is $($now -join ', '), expected $($expected -join ', '). The state file is kept."
            }
        } elseif ($null -ne $br) {
            Invoke-AppCmd @('set', 'config', "-section:$Section", "/-[name='br']", '/commit:apphost') | Out-Null
        }
        foreach ($a in $proxyRestore) {
            Invoke-AppCmd @('set', 'config', "-section:$Section", "/${a}:$($state.PreviousProxy.$a)", '/commit:apphost') | Out-Null
        }
        Remove-Item -Path $StateFile -Confirm:$false
        $applied = $true
    }

    Write-Host 'Schemes now:'
    Show-Schemes (Get-CompressionConfig)
    Write-Host "Full applicationHost.config backup kept: appcmd restore backup `"$($state.Backup)`" (reverts every later change)."
    Complete-Activation -SchemeChanged ($applied -and ($null -ne $previousAttrs -or $null -ne $br)) -ProxyChanged ($applied -and $proxyRestore.Count -gt 0)
    return
}

# ---------------------------------------------------------------------------- install
# PF_AVX2_INSTRUCTIONS_AVAILABLE = 40. An AVX2-less CPU would crash w3wp.exe on load.
if (-not ('BrotliIis.Cpu' -as [type])) {
    # A second run in the same PowerShell session would otherwise fail: the type already exists.
    Add-Type -Namespace BrotliIis -Name Cpu -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint feature);'
}
if (-not [BrotliIis.Cpu]::IsProcessorFeaturePresent(40)) {
    throw 'This CPU (or VM CPU model) does not report AVX2; the DLL is built with /arch:AVX2 and would crash w3wp.exe.'
}

$source = (Resolve-Path -LiteralPath $DllPath).ProviderPath
$hash   = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
if ($hash -ne $ExpectedSha256.ToUpperInvariant()) {
    throw "SHA-256 mismatch for $source`n  expected $($ExpectedSha256.ToUpperInvariant())`n  actual   $hash"
}

$fileVersion = (Get-Item -LiteralPath $source).VersionInfo.FileVersion
if ($fileVersion -notmatch '^(\d+)\.(\d+)\.(\d+)') { throw "Unexpected FileVersion '$fileVersion' in $source." }
$version = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
$target  = Join-Path $TargetDir "brotli-$version.dll"

$config  = Get-CompressionConfig
$br      = Get-BrScheme $config
Write-Host "brotli $version, SHA-256 verified. Target: $target"
Write-Host 'Schemes before:'
Show-Schemes $config

$copyNeeded = $true
if (Test-Path -LiteralPath $target) {
    $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($targetHash -ne $hash) {
        throw "$target already exists with a different SHA-256 ($targetHash). Refusing to overwrite a DLL that w3wp.exe may have loaded."
    }
    $copyNeeded = $false
}

# The wanted br scheme: the existing one's attributes (doStaticCompression,
# doDynamicCompression, ...) with the DLL and levels replaced, or a new entry with IIS defaults.
$wantedAttrs = [ordered]@{ name = 'br' }
if ($null -ne $br) { foreach ($k in $br.Attrs.Keys) { $wantedAttrs[$k] = $br.Attrs[$k] } }
$wantedAttrs['dll'] = $target
$wantedAttrs['dynamicCompressionLevel'] = "$DynamicLevel"
$wantedAttrs['staticCompressionLevel'] = "$StaticLevel"

$schemeNeeded = ($null -eq $br) -or ($br.Position -ne 'start') -or
                @($wantedAttrs.Keys | Where-Object { "$($br.Attrs[$_])" -ne "$($wantedAttrs[$_])" }).Count -gt 0
$proxyWanted = @{ noCompressionForProxies = 'false'; staticCompressionIgnoreHitFrequency = 'true' }
$proxyNeeded = $ProxyFriendly -and @($ProxyAttrs | Where-Object { $config.Proxy[$_] -ne $proxyWanted[$_] }).Count -gt 0

if (-not ($copyNeeded -or $schemeNeeded -or $proxyNeeded)) {
    Write-Host 'Already installed with these settings; nothing to change.'
} else {
    $backup = 'brotli-iis-' + (Get-Date -Format 'yyyyMMdd-HHmmss')

    # Rollback baseline. An earlier install that did not finish left its state file with
    # Completed = false; its baseline is the configuration before that attempt, so keep it
    # rather than record the half-changed configuration as "previous".
    $state = $null
    if (Test-Path $StateFile) {
        $old = Get-Content -Raw -Path $StateFile | ConvertFrom-Json
        if (-not ($old.PSObject.Properties['Completed'] -and $old.Completed)) {
            Write-Warning "An earlier install (backup $($old.Backup)) did not finish; keeping its recorded baseline for -Rollback."
            $state = @{ Backup = $old.Backup; PreviousBr = $old.PreviousBr; PreviousProxy = $old.PreviousProxy; PreviousOrder = $old.PreviousOrder }
        }
    }
    if ($null -eq $state) {
        $previousBr = $null
        if ($null -ne $br) { $previousBr = @{ Attrs = $br.Attrs; Position = $br.Position } }
        $state = @{ Backup = $backup; PreviousBr = $previousBr; PreviousProxy = $config.Proxy; PreviousOrder = @($config.Schemes | ForEach-Object { $_.Name }) }
    }
    $state['Installed'] = $target
    $state['Completed'] = $false

    $plan = @("appcmd backup $backup", "record the rollback baseline in $StateFile")
    if ($copyNeeded)   { $plan += "copy the DLL to $target" }
    if ($schemeNeeded) { $plan += "register br first: dll=$target dynamic=$DynamicLevel static=$StaticLevel" }
    if ($proxyNeeded)  { $plan += 'set noCompressionForProxies=false, staticCompressionIgnoreHitFrequency=true' }

    # One confirmation for the whole change set: under -Confirm no step can run without the
    # backup and the rollback baseline that precede it.
    if ($PSCmdlet.ShouldProcess($Section, ($plan -join '; '))) {
        Invoke-AppCmd @('add', 'backup', $backup) | Out-Null
        Write-State $state
        Write-Host "Backup: $backup. If a later step fails: .\install-iis.ps1 -Rollback (or appcmd restore backup `"$backup`")."
        if ($copyNeeded) {
            Copy-Item -LiteralPath $source -Destination $target -Confirm:$false
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $hash) { throw "Copied file $target does not match the verified SHA-256." }
        }
        if ($schemeNeeded) { Set-BrScheme -Attrs $wantedAttrs -Position 'start' -Current $br }
        if ($proxyNeeded) {
            Invoke-AppCmd @('set', 'config', "-section:$Section", '/noCompressionForProxies:false', '/staticCompressionIgnoreHitFrequency:true', '/commit:apphost') | Out-Null
        }

        $after = Get-CompressionConfig
        Write-Host 'Schemes after:'
        Show-Schemes $after
        $afterBr = Get-BrScheme $after
        if ($null -eq $afterBr -or $afterBr.Position -ne 'start' -or $afterBr.Attrs['dll'] -ne $target) {
            throw 'Post-check failed: br is not the first scheme or does not point at the installed DLL. Run .\install-iis.ps1 -Rollback.'
        }
        $state['Completed'] = $true
        Write-State $state
        Write-Host "Installed. To undo: .\install-iis.ps1 -Rollback -RestartWww"
        $applied = $true
    }
}

Complete-Activation -SchemeChanged ($applied -and ($copyNeeded -or $schemeNeeded)) -ProxyChanged ($applied -and $proxyNeeded)
