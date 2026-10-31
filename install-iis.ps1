#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install or update the Brotli-IIS "br" compression scheme on this IIS server.

.DESCRIPTION
    Deploys a prebuilt brotli.dll (no build on the target). Runs on Windows PowerShell 5.1
    and PowerShell 7. IIS configuration changes go through appcmd.exe; the DLL copy, the undo
    note and the service restart are the only other changes. -WhatIf lists the changes and
    makes none; -Confirm asks once for the whole configuration change set, and once more
    for the service restart when -RestartWww is given.

      1. Preflight: 64-bit OS, IIS present, static + dynamic compression modules present,
         CPU reports AVX2 (the DLL is built with /arch:AVX2), DLL SHA-256 = -ExpectedSha256,
         and curl.exe present when -VerifyUrl is given.
      2. appcmd backup of applicationHost.config, named brotli-iis-<timestamp>.
      3. Undo note brotli-iis-undo-<timestamp>.txt next to the DLLs, written before any
         configuration change: PowerShell commands, runnable from any directory, that put
         the previous br entry's settings back (pointing at the previous DLL file), set the
         previous proxy attributes and restart the service, plus the backup to restore for a
         full revert (which also restores br's previous position).
      4. Copy the DLL to %ProgramFiles%\IIS\IIS Compression\brotli-<major.minor.patch>.dll
         (a versioned name, because w3wp.exe keeps a loaded DLL locked; the previous file
         stays in place, which is what the undo commands point at again).
      5. Register or repoint the "br" scheme as the FIRST scheme, so it precedes gzip/deflate
         (IIS 10 1803+ uses registration order to break ties between equal q-values). An
         existing br entry keeps its other attributes (doStaticCompression, ...).
      6. Optional -ProxyFriendly: noCompressionForProxies=false and
         staticCompressionIgnoreHitFrequency=true, so requests arriving through a CDN or
         proxy (Via header) are compressed, and static files from the first hit.

    A scheme dll or level change takes effect only after a WWW service restart (Microsoft
    scheme reference); -RestartWww does it, otherwise the commands are printed. -VerifyUrl
    requires -RestartWww, so it never checks a worker that still runs the previous DLL.
    Re-running with the same inputs changes nothing.

.EXAMPLE
    .\install-iis.ps1 -DllPath .\brotli.dll -ExpectedSha256 <sha256 from SHA256SUMS> -ProxyFriendly -WhatIf
.EXAMPLE
    .\install-iis.ps1 -DllPath .\brotli.dll -ExpectedSha256 <sha256> -ProxyFriendly -RestartWww -VerifyUrl https://www.example.com/some.css
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$DllPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ExpectedSha256,

    [ValidateRange(0, 11)]
    [int]$DynamicLevel = 4,

    [ValidateRange(0, 11)]
    [int]$StaticLevel = 10,

    [switch]$ProxyFriendly,

    [switch]$RestartWww,

    [string]$VerifyUrl
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Section    = 'system.webServer/httpCompression'
$AppCmd     = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
$Curl       = Join-Path $env:windir 'System32\curl.exe'
$TargetDir  = Join-Path $env:ProgramFiles 'IIS\IIS Compression'
$ProxyAttrs = @('noCompressionForProxies', 'staticCompressionIgnoreHitFrequency')

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
        $schemes += [pscustomobject]@{ Name = $attrs['name']; Attrs = $attrs; First = ($i -eq 0) }
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

# Makes br the first scheme carrying exactly $Attrs. Already first: every attribute is set in
# place in one appcmd commit. Otherwise it is removed and re-added at @start: two commits, so
# for a moment the server has no br scheme (running workers keep their loaded DLL until the
# WWW service restarts). No other scheme is touched.
function Set-BrSchemeFirst([System.Collections.IDictionary]$Attrs, [object]$Current) {
    foreach ($k in $Attrs.Keys) {
        if ("$($Attrs[$k])".Contains("'")) { throw "Scheme attribute $k contains a single quote, which appcmd cannot take: $($Attrs[$k])" }
    }
    if ($null -ne $Current -and $Current.First) {
        $sets = @($Attrs.Keys | Where-Object { $_ -ne 'name' } | ForEach-Object { "/[name='br'].${_}:$($Attrs[$_])" })
        Invoke-AppCmd (@('set', 'config', "-section:$Section") + $sets + @('/commit:apphost')) | Out-Null
        return
    }
    if ($null -ne $Current) {
        Invoke-AppCmd @('set', 'config', "-section:$Section", "/-[name='br']", '/commit:apphost') | Out-Null
    }
    $list = (@($Attrs.Keys) | ForEach-Object { "$_='$($Attrs[$_])'" }) -join ','
    Invoke-AppCmd @('set', 'config', "-section:$Section", "/+[@start,$list]", '/commit:apphost') | Out-Null
}

# The undo note: PowerShell commands, runnable from any directory (appcmd.exe is not on PATH
# by default, so it is called by full path), that put back the configuration this install
# replaces. The previous br entry is restored attribute by attribute, so it points at the
# preserved DLL file whatever its name or version.
function Get-UndoText([object]$Br, [System.Collections.IDictionary]$Proxy, [string]$Backup) {
    # PowerShell single-quoted literal: nothing in a value ($, backtick) is interpreted.
    function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
    $call = "& $(Q $AppCmd) set config $(Q "-section:$Section")"
    $lines = @("# brotli-iis undo note, written $(Get-Date -Format 's') with appcmd backup $Backup. Run in an elevated PowerShell.", '')
    if ($null -eq $Br) {
        $lines += '# br was not registered before. Remove it:'
        $lines += "$call $(Q "/-[name='br']") /commit:apphost"
    } else {
        $where = 'NOT the first scheme; this restores its settings, the full revert below restores its position'
        if ($Br.First) { $where = 'the first scheme' }
        $lines += "# Previous br entry ($where). Put its settings back:"
        $sets = @($Br.Attrs.Keys | Where-Object { $_ -ne 'name' } | ForEach-Object { Q "/[name='br'].${_}:$($Br.Attrs[$_])" })
        $lines += "$call $($sets -join ' ') /commit:apphost"
        $prevDll = [Environment]::ExpandEnvironmentVariables($Br.Attrs['dll'])
        if (-not (Test-Path -LiteralPath $prevDll)) { $lines += "# WARNING: the previous DLL file $prevDll is missing; use the full revert below." }
    }
    $lines += '# Previous proxy attributes (only needed if -ProxyFriendly changed them):'
    $lines += "$call $((@($Proxy.Keys) | ForEach-Object { Q "/${_}:$($Proxy[$_])" }) -join ' ') /commit:apphost"
    $lines += '# Then restart the WWW service so the workers load the previous DLL (a brief interruption for every site):'
    $lines += 'Restart-Service W3SVC -Force'
    $lines += ''
    $lines += '# Full revert of applicationHost.config instead (also undoes every later change by anyone):'
    $lines += "& $(Q $AppCmd) restore backup $(Q $Backup)"
    return $lines
}

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

# ---------------------------------------------------------------------------- preflight
if ($VerifyUrl -and -not $RestartWww) { throw '-VerifyUrl requires -RestartWww: without a restart the workers may still run the previous DLL.' }
if ($VerifyUrl -and -not (Test-Path $Curl)) { throw "-VerifyUrl needs $Curl, which is not present." }
if (-not [Environment]::Is64BitOperatingSystem) { throw 'This DLL is x64; the operating system is not 64-bit.' }
if (-not (Test-Path $AppCmd)) { throw "IIS is not installed ($AppCmd not found)." }

[xml]$modulesXml = (Invoke-AppCmd @('list', 'config', '-section:system.webServer/globalModules', '/xml')) -join "`n"
foreach ($m in @('StaticCompressionModule', 'DynamicCompressionModule')) {
    if ($null -eq $modulesXml.SelectSingleNode("//add[@name='$m']")) {
        throw "IIS module $m is not installed. Install the IIS role features Web-Stat-Compression and Web-Dyn-Compression first."
    }
}

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

# ---------------------------------------------------------------------------- what changes
$config = Get-CompressionConfig
$br     = Get-BrScheme $config
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

$schemeNeeded = ($null -eq $br) -or (-not $br.First) -or
                @($wantedAttrs.Keys | Where-Object { "$($br.Attrs[$_])" -ne "$($wantedAttrs[$_])" }).Count -gt 0
$proxyWanted = @{ noCompressionForProxies = 'false'; staticCompressionIgnoreHitFrequency = 'true' }
$proxyNeeded = $ProxyFriendly -and @($ProxyAttrs | Where-Object { $config.Proxy[$_] -ne $proxyWanted[$_] }).Count -gt 0

# ---------------------------------------------------------------------------- apply
$applied = $false
if (-not ($copyNeeded -or $schemeNeeded -or $proxyNeeded)) {
    Write-Host 'Already installed with these settings; nothing to change.'
} else {
    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup   = "brotli-iis-$stamp"
    $undoFile = Join-Path $TargetDir "brotli-iis-undo-$stamp.txt"

    $plan = @("appcmd backup $backup", "write the undo note $undoFile")
    if ($copyNeeded)   { $plan += "copy the DLL to $target" }
    if ($schemeNeeded) { $plan += "register br first: dll=$target dynamic=$DynamicLevel static=$StaticLevel" }
    if ($proxyNeeded)  { $plan += 'set noCompressionForProxies=false, staticCompressionIgnoreHitFrequency=true' }

    # One confirmation for the whole change set; -Confirm:$false on the cmdlets inside keeps a
    # nested prompt from skipping a step the next ones depend on.
    if ($PSCmdlet.ShouldProcess($Section, ($plan -join '; '))) {
        Invoke-AppCmd @('add', 'backup', $backup) | Out-Null
        New-Item -ItemType Directory -Force -Path $TargetDir -Confirm:$false | Out-Null
        $undo = Get-UndoText -Br $br -Proxy $config.Proxy -Backup $backup
        Set-Content -Path $undoFile -Value $undo -Encoding UTF8 -Confirm:$false
        Write-Host "Backup $backup taken; undo note: $undoFile"

        if ($copyNeeded) {
            Copy-Item -LiteralPath $source -Destination $target -Confirm:$false
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $hash) { throw "Copied file $target does not match the verified SHA-256." }
        }
        if ($schemeNeeded) { Set-BrSchemeFirst -Attrs $wantedAttrs -Current $br }
        if ($proxyNeeded) {
            Invoke-AppCmd @('set', 'config', "-section:$Section", '/noCompressionForProxies:false', '/staticCompressionIgnoreHitFrequency:true', '/commit:apphost') | Out-Null
        }

        $after = Get-CompressionConfig
        Write-Host 'Schemes after:'
        Show-Schemes $after
        $afterBr = Get-BrScheme $after
        if ($null -eq $afterBr -or -not $afterBr.First -or
            @($wantedAttrs.Keys | Where-Object { "$($afterBr.Attrs[$_])" -ne "$($wantedAttrs[$_])" }).Count -gt 0) {
            throw "Post-check failed: br is not the first scheme with the requested settings. See $undoFile."
        }
        $applied = $true
        Write-Host ''
        $undo | ForEach-Object { Write-Host $_ }
    }
}

# ---------------------------------------------------------------------------- activate
# Restart and verify only for a configuration that is now the requested one: applied by this
# run, or already matching. A declined change set stops here, so -VerifyUrl can never certify
# the previous DLL. (-WhatIf continues, to show the restart it would do.)
$alreadyCurrent = -not ($copyNeeded -or $schemeNeeded -or $proxyNeeded)
if (-not ($applied -or $alreadyCurrent -or $WhatIfPreference)) {
    Write-Host 'The change set was declined; no restart and no verification.'
    return
}
if ($RestartWww) {
    $restarted = Restart-Www
    if ($VerifyUrl) {
        if ($restarted) { Test-BrResponse $VerifyUrl }
        else { Write-Host '-VerifyUrl skipped: the WWW service was not restarted (-WhatIf or declined).' }
    }
} elseif ($applied -and ($copyNeeded -or $schemeNeeded)) {
    Write-Host ''
    Write-Host 'The new scheme takes effect after a WWW service restart (a brief interruption for every site):'
    Write-Host '  net stop w3svc /y'
    Write-Host '  net start w3svc'
    Write-Host 'or re-run this script with -RestartWww.'
} elseif ($applied -and $proxyNeeded) {
    # <httpCompression> element attributes apply once the application pools recycle.
    Write-Host ''
    Write-Host 'The proxy settings take effect when the application pools recycle (or after a WWW service restart):'
    Write-Host "  & '$AppCmd' list apppool /xml | & '$AppCmd' recycle apppool /in"
}
