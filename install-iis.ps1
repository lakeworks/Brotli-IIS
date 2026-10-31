#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install, update or roll back the Brotli-IIS "br" compression scheme on this IIS server.

.DESCRIPTION
    Deploys a prebuilt brotli.dll (no build on the target). Runs on Windows PowerShell 5.1
    and PowerShell 7. Every change goes through appcmd.exe; -WhatIf shows each change and
    makes none.

    Install:
      1. Preflight: 64-bit OS, IIS present, static + dynamic compression modules present,
         CPU reports AVX2 (the DLL is built with /arch:AVX2), DLL SHA-256 = -ExpectedSha256.
      2. appcmd backup of applicationHost.config, named brotli-iis-<timestamp>.
      3. Copy the DLL to %ProgramFiles%\IIS\IIS Compression\brotli-<major.minor.patch>.dll
         (a versioned name, because w3wp.exe keeps a loaded DLL locked; the previous file
         stays in place for rollback).
      4. Register or repoint the "br" scheme as the FIRST scheme, so it precedes gzip/deflate
         (IIS 10 1803+ uses registration order to break ties between equal q-values).
      5. Optional -ProxyFriendly: noCompressionForProxies=false and
         staticCompressionIgnoreHitFrequency=true, so requests arriving through a CDN or
         proxy (Via header) are compressed, and static files from the first hit.
      6. Write a state file next to the DLL recording what was there before, for -Rollback.
    A scheme dll or level change takes effect only after a WWW service restart (Microsoft
    scheme reference); -RestartWww does it, otherwise the commands are printed.

    Rollback: restores the "br" scheme and the two -ProxyFriendly attributes recorded by the
    last install that changed something. Other configuration is left alone. The full
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

    [string]$VerifyUrl
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Section    = 'system.webServer/httpCompression'
$AppCmd     = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
$TargetDir  = Join-Path $env:ProgramFiles 'IIS\IIS Compression'
$StateFile  = Join-Path $TargetDir 'brotli-iis-state.json'
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
    $schemes = @()
    foreach ($s in $node.SelectNodes('scheme')) {
        $schemes += [pscustomobject]@{
            Name    = $s.GetAttribute('name')
            Dll     = $s.GetAttribute('dll')
            Dynamic = $s.GetAttribute('dynamicCompressionLevel')
            Static  = $s.GetAttribute('staticCompressionLevel')
        }
    }
    $proxy = @{}
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
        Write-Host ("  {0}. {1,-8} {2}  dynamic={3} static={4}" -f $i, $s.Name, $s.Dll, $s.Dynamic, $s.Static)
    }
}

# Removes the br scheme, then adds it back as the first entry. Two appcmd commits: for a
# moment the server has no br scheme; running workers keep their loaded DLL until restart.
function Set-BrScheme([string]$Dll, [string]$Dynamic, [string]$Static, [bool]$Exists) {
    if ($Dll.Contains("'")) { throw "DLL path contains a single quote, which appcmd cannot take: $Dll" }
    $attrs = "name='br',dll='$Dll'"
    if ($Dynamic -ne '') { $attrs += ",dynamicCompressionLevel='$Dynamic'" }
    if ($Static -ne '')  { $attrs += ",staticCompressionLevel='$Static'" }
    if ($Exists) {
        Invoke-AppCmd @('set', 'config', "-section:$Section", "/-[name='br']", '/commit:apphost') | Out-Null
    }
    Invoke-AppCmd @('set', 'config', "-section:$Section", "/+[@start,$attrs]", '/commit:apphost') | Out-Null
}

function Restart-Www {
    if ($PSCmdlet.ShouldProcess('W3SVC', 'Restart the World Wide Web Publishing Service (brief interruption for every site)')) {
        Restart-Service -Name W3SVC -Force
        Write-Host 'W3SVC restarted.'
    }
}

function Test-BrResponse([string]$Url) {
    $curl = Join-Path $env:windir 'System32\curl.exe'
    if (-not (Test-Path $curl)) { Write-Warning "curl.exe not found; skipping the -VerifyUrl check."; return }
    $headers = & $curl -sS -o NUL -D - --max-time 30 -H 'Accept-Encoding: br' $Url 2>&1
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

# ---------------------------------------------------------------------------- preflight
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

    if ($PSCmdlet.ShouldProcess($Section, 'Restore the br scheme recorded before the last install')) {
        if ($state.PreviousBr) {
            Set-BrScheme -Dll $state.PreviousBr.Dll -Dynamic $state.PreviousBr.Dynamic -Static $state.PreviousBr.Static -Exists ($null -ne $br)
        } elseif ($null -ne $br) {
            Invoke-AppCmd @('set', 'config', "-section:$Section", "/-[name='br']", '/commit:apphost') | Out-Null
        }
    }
    foreach ($a in $ProxyAttrs) {
        $old = $state.PreviousProxy.$a
        if ($old -ne $config.Proxy[$a] -and $PSCmdlet.ShouldProcess($Section, "Set $a back to '$old'")) {
            if ($old -eq '') {
                Invoke-AppCmd @('set', 'config', "-section:$Section", "/-$a", '/commit:apphost') | Out-Null
            } else {
                Invoke-AppCmd @('set', 'config', "-section:$Section", "/${a}:$old", '/commit:apphost') | Out-Null
            }
        }
    }
    if ($PSCmdlet.ShouldProcess($StateFile, 'Remove the install state file')) { Remove-Item -Path $StateFile }

    Write-Host 'Schemes now:'
    Show-Schemes (Get-CompressionConfig)
    Write-Host "Full applicationHost.config backup kept: appcmd restore backup `"$($state.Backup)`" (reverts every later change)."
    if ($RestartWww) { Restart-Www } else { Write-RestartNote }
    if ($VerifyUrl) { Write-Host 'Skipping -VerifyUrl after a rollback.' }
    return
}

# ---------------------------------------------------------------------------- install
# PF_AVX2_INSTRUCTIONS_AVAILABLE = 40. An AVX2-less CPU would crash w3wp.exe on load.
Add-Type -Namespace BrotliIis -Name Cpu -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint feature);'
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

$schemeNeeded = ($null -eq $br) -or
                ($br.Dll -ne $target) -or
                ($br.Dynamic -ne "$DynamicLevel") -or
                ($br.Static -ne "$StaticLevel") -or
                ($config.Schemes[0].Name -ne 'br')
$proxyWanted = @{ noCompressionForProxies = 'false'; staticCompressionIgnoreHitFrequency = 'true' }
$proxyNeeded = $ProxyFriendly -and @($ProxyAttrs | Where-Object { $config.Proxy[$_] -ne $proxyWanted[$_] }).Count -gt 0

if (-not ($copyNeeded -or $schemeNeeded -or $proxyNeeded)) {
    Write-Host 'Already installed with these settings; nothing to change.'
} else {
    $backup = 'brotli-iis-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    if ($PSCmdlet.ShouldProcess('applicationHost.config', "Create appcmd backup $backup")) {
        Invoke-AppCmd @('add', 'backup', $backup) | Out-Null
    }
    if ($copyNeeded -and $PSCmdlet.ShouldProcess($target, "Copy $source")) {
        New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
        Copy-Item -LiteralPath $source -Destination $target
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $hash) { throw "Copied file $target does not match the verified SHA-256." }
    }
    if ($schemeNeeded -and $PSCmdlet.ShouldProcess($Section, "Set scheme br first: dll=$target dynamic=$DynamicLevel static=$StaticLevel")) {
        Set-BrScheme -Dll $target -Dynamic "$DynamicLevel" -Static "$StaticLevel" -Exists ($null -ne $br)
    }
    if ($proxyNeeded -and $PSCmdlet.ShouldProcess($Section, 'Set noCompressionForProxies=false, staticCompressionIgnoreHitFrequency=true')) {
        Invoke-AppCmd @('set', 'config', "-section:$Section", '/noCompressionForProxies:false', '/staticCompressionIgnoreHitFrequency:true', '/commit:apphost') | Out-Null
    }
    if ($PSCmdlet.ShouldProcess($StateFile, 'Record the previous configuration for -Rollback')) {
        $previousBr = $null
        if ($null -ne $br) { $previousBr = @{ Dll = $br.Dll; Dynamic = $br.Dynamic; Static = $br.Static } }
        @{ Backup = $backup; PreviousBr = $previousBr; PreviousProxy = $config.Proxy; Installed = $target } |
            ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8
    }
    Write-Host "Backup: $backup"
}

if (-not $WhatIfPreference) {
    $after = Get-CompressionConfig
    Write-Host 'Schemes after:'
    Show-Schemes $after
    if ($after.Schemes[0].Name -ne 'br' -or (Get-BrScheme $after).Dll -ne $target) {
        throw 'Post-check failed: br is not the first scheme or does not point at the installed DLL.'
    }
}

$changed = $copyNeeded -or $schemeNeeded
if ($RestartWww) {
    Restart-Www
    if ($VerifyUrl) { Test-BrResponse $VerifyUrl }
} else {
    if ($changed) { Write-RestartNote }
    if ($VerifyUrl) {
        if ($changed) { Write-Host 'Skipping -VerifyUrl: the new scheme is not active until the WWW service restarts.' }
        else { Test-BrResponse $VerifyUrl }
    }
}
