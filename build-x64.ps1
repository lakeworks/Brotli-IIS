# Build Brotli-IIS for x64.
#
# Output: out/brotli.dll  (last-build-wins; the bench's matrix runner copies
# this into out/variants/<variant>/brotli.dll for cross-arch comparisons)
#
# Parameters:
#   -Arch <avx2|sse2>  default: avx2
#     avx2 -- /arch:AVX2 baseline (Intel Haswell+ / AMD Excavator+ / Zen+)
#     sse2 -- x64 default codegen (no /arch: flag); SSE2 is implicit since
#            x64 ABI already mandates it. Used for the AVX2-vs-SSE2 keep/drop
#            measurement in the bench matrix.
#
# Prerequisites:
#   - Visual Studio 2022 Build Tools with the C++ workload + Windows SDK
#   - Git (for vcpkg submodule)
#
# This wraps the upstream vcpkg-based build with an arch-specific overlay
# triplet (win-x64-avx2 / win-x64-sse2). The upstream win-x64.cmake /
# shared.cmake stay unmodified so we can pull upstream changes without merge
# conflicts. vcpkg keys buildtrees by triplet name, so swapping triplets
# forces a fresh compile of the brotli dependency port -- no stale-buildtree
# reuse across arch variants.

param(
    [ValidateSet('avx2','sse2')]
    [string]$Arch = 'avx2'
)

$ErrorActionPreference = 'Stop'

# Note: $ErrorActionPreference = 'Stop' converts cmdlet errors into terminating
# exceptions, but native exe non-zero exits set $LASTEXITCODE without throwing.
# Every native invocation below MUST be followed by an explicit
# `if ($LASTEXITCODE -ne 0) { throw ... }` check. If you add another `& <native>`
# call, add the check at the same time.

$repoRoot = $PSScriptRoot
$vcpkgRoot = Join-Path $repoRoot 'vcpkg'
$buildRoot = Join-Path $repoRoot 'build'
$tripletName = "win-x64-$Arch"
$overlayDir = Join-Path $buildRoot "vcpkg-overlay-$Arch"
$outDir = Join-Path $repoRoot 'out'

# Arch-specific compiler flag. SSE2 is the x64 default -- we pass *no* /arch:
# flag in that case rather than /arch:SSE2 (MSVC accepts /arch:SSE2 but emits
# the same code as the unflagged baseline; using the absence is more honest).
$archFlag = if ($Arch -eq 'avx2') { '/arch:AVX2' } else { '' }
$archDescription = if ($Arch -eq 'avx2') { 'AVX2 (Intel Haswell+ / AMD Excavator+ / Zen+)' } else { 'SSE2 (x64 baseline; no /arch: flag)' }

if (-not (Test-Path (Join-Path $vcpkgRoot 'bootstrap-vcpkg.bat'))) {
    throw "vcpkg submodule missing. Run: git submodule update --init --recursive"
}

Write-Host "[1/5] Bootstrapping vcpkg..." -ForegroundColor Cyan
$vcpkgExe = Join-Path $vcpkgRoot 'vcpkg.exe'
# Always re-bootstrap. bootstrap-vcpkg.bat is idempotent -- it checks the
# embedded toolversion against the existing vcpkg.exe and only re-downloads
# when the submodule has been advanced past what the current binary supports.
# Skipping bootstrap when vcpkg.exe is merely *present* (the previous guard)
# left an old vcpkg-tool binary running against newer ports/scripts after a
# `git submodule update` -- the documented update path in CLAUDE.md.
& (Join-Path $vcpkgRoot 'bootstrap-vcpkg.bat') -disableMetrics
if ($LASTEXITCODE -ne 0) { throw "vcpkg bootstrap failed" }

Write-Host "[2/5] Preparing $($Arch.ToUpper()) overlay triplet..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $overlayDir | Out-Null

# Custom triplet inheriting upstream + injecting the arch-specific CL flag
# alongside /GL (whole-program optimization).
$archCFlags = (@('/GL', $archFlag) | Where-Object { $_ }) -join ' '
$tripletContent = @"
include(`${CMAKE_CURRENT_LIST_DIR}/../vcpkg/shared.cmake)

set(VCPKG_DISABLE_COMPILER_TRACKING true)
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE static)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_BUILD_TYPE release)

# $archDescription
# Combined with /GL + /LTCG from shared.cmake for whole-program optimization.
set(VCPKG_C_FLAGS_RELEASE "$archCFlags")
set(VCPKG_CXX_FLAGS_RELEASE "$archCFlags")

if(PORT IN_LIST _PKG_LIBS)
  set(VCPKG_LIBRARY_LINKAGE dynamic)
endif()
"@

$tripletPath = Join-Path $overlayDir "$tripletName.cmake"
Set-Content -Path $tripletPath -Value $tripletContent -Encoding ASCII

Write-Host "[3/5] Building Brotli library (vcpkg) with $($Arch.ToUpper())..." -ForegroundColor Cyan

# Arch flag delivery: the overlay triplet sets
#   VCPKG_C_FLAGS_RELEASE = "/GL [/arch:AVX2 if applicable]"
# AFTER include(shared.cmake), so it overrides the upstream "/GL"-only value.
# vcpkg keys buildtrees by triplet name, so swapping win-x64 for
# win-x64-<arch> forces a fresh compile of the brotli dependency port -- no
# stale-buildtree reuse across arch variants.

# Why no post-build SIMD-verify: brotli's encoder is entropy-coding-dominated
# and uses no SIMD intrinsics (verified against google/brotli@1.1.0 source),
# so whether AVX2 actually emits in the .obj is a perf curiosity, not a
# correctness property. The flag stays for symmetry with the zstd-IIS overlay
# (where AVX2 does pay off ~2-5%). See CLAUDE.md for the full rationale.

# Save and restore env vars so the build script doesn't leak state into
# the calling PowerShell session (where it would affect subsequent vcpkg
# invocations the user might run by hand).
$prevBinarySources = $env:VCPKG_BINARY_SOURCES
$prevOverlayTriplets = $env:VCPKG_OVERLAY_TRIPLETS

try {
    $env:VCPKG_BINARY_SOURCES = 'clear'  # disable any cached cross-arch binaries
    $env:VCPKG_OVERLAY_TRIPLETS = $overlayDir

    # vcpkg expects a response file; reuse the upstream one.
    $responseFile = Join-Path $repoRoot 'build/vcpkg/response'

    # Push to repo root so vcpkg's relative path resolution (for the response
    # file's --overlay-ports references etc.) lands on our checked-out tree
    # rather than the caller's cwd.
    Push-Location $repoRoot
    try {
        # vcpkg "already installed" short-circuit, two layers:
        #
        # (a) The brotli-iis overlay port (build/vcpkg/ports/brotli-iis/
        #     portfile.cmake) copies plugin sources from ${REPO_ROOT}/src into
        #     the per-build source path. vcpkg's installed-package metadata
        #     only hashes the port files (portfile.cmake + vcpkg.json), not
        #     the external sources. A local edit to src/brotli.c won't
        #     invalidate the installed package -- `vcpkg install` short-
        #     circuits and the post-build copy ships a stale DLL.
        #
        # (b) The brotli library dependency itself (vcpkg/ports/brotli/) is
        #     installed alongside brotli-iis under the same triplet root.
        #     After a vcpkg submodule advance that updates brotli's port
        #     (the documented update flow in CLAUDE.md), removing only
        #     brotli-iis leaves the *old* brotli static lib in the install
        #     tree -- vcpkg considers brotli satisfied and the rebuilt
        #     plugin DLL still links against the prior brotli release.
        #
        # Remove both before install. Two failure detectors, because either
        # alone has a gap:
        #   1. The remove call's exit code. A non-zero exit carrying a benign
        #      "not installed" message is fine to swallow (nothing to remove
        #      on a first-ever build), but a vcpkg.exe-missing / bootstrap-
        #      corrupt / triplet-parse failure must surface -- 2>&1 | Out-Null
        #      plus a blanket $LASTEXITCODE=0 (the previous form) silenced it.
        #   2. An on-disk check that neither package's metadata survives --
        #      catches a remove that exited 0 but left residue.
        $removeOutput = & $vcpkgExe remove "brotli-iis:$tripletName" "brotli:$tripletName" "@$responseFile" 2>&1
        if ($LASTEXITCODE -ne 0) {
            $removeText = ($removeOutput | Out-String)
            if ($removeText -notmatch 'not installed') {
                throw "vcpkg remove failed (exit ${LASTEXITCODE}):`n$removeText"
            }
        }

        # vcpkg classic-mode keeps installed-package metadata in the SHARED
        # install root's vcpkg/info dir (out/vcpkg/install/vcpkg/info), as
        # <pkg>_<version>_<triplet>.list -- NOT under the per-triplet
        # out/vcpkg/install/<triplet>/ subtree (which holds only bin/lib/...).
        # The previous path never existed, so the residual-package check was
        # silently skipped on every build. The filename filter is scoped to
        # $tripletName so a sibling arch variant's metadata cannot
        # false-positive this build.
        $vcpkgInfoDir = Join-Path $repoRoot 'out/vcpkg/install/vcpkg/info'
        if (Test-Path $vcpkgInfoDir) {
            $tripletEsc = [Regex]::Escape($tripletName)
            $stillInstalled = Get-ChildItem $vcpkgInfoDir -Filter '*.list' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "^(brotli|brotli-iis)_.+_$tripletEsc\.list`$" }
            if ($stillInstalled) {
                throw "vcpkg remove did not clear the install tree (residual: $($stillInstalled.Name -join ', '))"
            }
        }

        & $vcpkgExe install "brotli-iis:$tripletName" "@$responseFile"
        if ($LASTEXITCODE -ne 0) { throw "vcpkg install failed" }
    } finally {
        Pop-Location
    }
} finally {
    $env:VCPKG_BINARY_SOURCES = $prevBinarySources
    $env:VCPKG_OVERLAY_TRIPLETS = $prevOverlayTriplets
}

Write-Host "[4/5] Locating built DLL..." -ForegroundColor Cyan
# vcpkg installs to a deterministic per-triplet path. Look only there:
# falling back to a recursive Get-ChildItem search risks picking up a
# stale DLL from a previous build, or worse -- the brotli library's own
# brotli.dll (different ABI from what IIS expects).
$built = Join-Path $repoRoot "out/vcpkg/install/$tripletName/bin/brotli.dll"
if (-not (Test-Path $built)) {
    throw "Could not locate built brotli.dll at expected path: $built"
}

Write-Host "[5/5] Copying to $outDir..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Copy-Item -Force $built -Destination (Join-Path $outDir 'brotli.dll')

$info = Get-Item (Join-Path $outDir 'brotli.dll')
Write-Host ""
Write-Host "Built:    $($info.FullName)" -ForegroundColor Green
Write-Host "Size:     $($info.Length) bytes"
Write-Host "Modified: $($info.LastWriteTime)"
