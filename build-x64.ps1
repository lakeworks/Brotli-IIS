# Build Brotli-IIS for x64 with AVX2 (Intel Haswell+ / AMD Excavator+).
#
# Output: out/brotli.dll
#
# Prerequisites:
#   - Visual Studio 2022 Build Tools with the C++ workload + Windows SDK
#   - Git (for vcpkg submodule)
#
# This wraps the upstream vcpkg-based build with an AVX2-enabled overlay triplet.
# The upstream win-x64.cmake / shared.cmake stay unmodified so we can pull
# upstream changes without merge conflicts.

$ErrorActionPreference = 'Stop'

# Note: $ErrorActionPreference = 'Stop' converts cmdlet errors into terminating
# exceptions, but native exe non-zero exits set $LASTEXITCODE without throwing.
# Every native invocation below MUST be followed by an explicit
# `if ($LASTEXITCODE -ne 0) { throw ... }` check. If you add another `& <native>`
# call, add the check at the same time.

$repoRoot = $PSScriptRoot
$vcpkgRoot = Join-Path $repoRoot 'vcpkg'
$buildRoot = Join-Path $repoRoot 'build'
$overlayDir = Join-Path $buildRoot 'vcpkg-overlay-avx2'
$outDir = Join-Path $repoRoot 'out'

if (-not (Test-Path (Join-Path $vcpkgRoot 'bootstrap-vcpkg.bat'))) {
    throw "vcpkg submodule missing. Run: git submodule update --init --recursive"
}

Write-Host "[1/5] Bootstrapping vcpkg..." -ForegroundColor Cyan
$vcpkgExe = Join-Path $vcpkgRoot 'vcpkg.exe'
# Always re-bootstrap. bootstrap-vcpkg.bat is idempotent — it checks the
# embedded toolversion against the existing vcpkg.exe and only re-downloads
# when the submodule has been advanced past what the current binary supports.
# Skipping bootstrap when vcpkg.exe is merely *present* (the previous guard)
# left an old vcpkg-tool binary running against newer ports/scripts after a
# `git submodule update` — the documented update path in CLAUDE.md.
& (Join-Path $vcpkgRoot 'bootstrap-vcpkg.bat') -disableMetrics
if ($LASTEXITCODE -ne 0) { throw "vcpkg bootstrap failed" }

Write-Host "[2/5] Preparing AVX2 overlay triplet..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $overlayDir | Out-Null

# Custom triplet inheriting upstream + adding /arch:AVX2 to CL flags.
$tripletContent = @'
include(${CMAKE_CURRENT_LIST_DIR}/../vcpkg/shared.cmake)

set(VCPKG_DISABLE_COMPILER_TRACKING true)
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE static)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_BUILD_TYPE release)

# AVX2 baseline: Intel Haswell (2013+) / AMD Excavator (2015+) / Zen (2017+).
# Combined with /GL + /LTCG from shared.cmake for whole-program optimization.
set(VCPKG_C_FLAGS_RELEASE "/GL /arch:AVX2")
set(VCPKG_CXX_FLAGS_RELEASE "/GL /arch:AVX2")

if(PORT IN_LIST _PKG_LIBS)
  set(VCPKG_LIBRARY_LINKAGE dynamic)
endif()
'@

$tripletPath = Join-Path $overlayDir 'win-x64-avx2.cmake'
Set-Content -Path $tripletPath -Value $tripletContent -Encoding ASCII

Write-Host "[3/5] Building Brotli library (vcpkg) with AVX2..." -ForegroundColor Cyan

# AVX2 flag delivery: the overlay triplet sets
#   VCPKG_C_FLAGS_RELEASE = "/GL /arch:AVX2"
# AFTER include(shared.cmake), so it overrides the upstream "/GL"-only value.
# vcpkg keys buildtrees by triplet name, so swapping win-x64 for win-x64-avx2
# forces a fresh compile of the brotli dependency port — no stale-buildtree
# reuse across triplet names.

# Why no post-build AVX2 verify: brotli's encoder is entropy-coding-dominated
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
    $env:VCPKG_BINARY_SOURCES = 'clear'  # disable any cached non-AVX2 binaries
    $env:VCPKG_OVERLAY_TRIPLETS = $overlayDir

    # vcpkg expects a response file; reuse the upstream one.
    $responseFile = Join-Path $repoRoot 'build/vcpkg/response'

    # Push to repo root so vcpkg's relative path resolution (for the response
    # file's --overlay-ports references etc.) lands on our checked-out tree
    # rather than the caller's cwd.
    Push-Location $repoRoot
    try {
        # The brotli-iis overlay port (build/vcpkg/ports/brotli-iis/portfile.cmake)
        # copies the plugin sources from ${REPO_ROOT}/src into vcpkg's per-build
        # source path. vcpkg's installed-package metadata only tracks the port
        # files themselves (portfile.cmake + vcpkg.json), not the external
        # sources. So when an already-installed brotli-iis exists, `vcpkg
        # install` short-circuits as "already installed" — even after a local
        # edit to src/brotli.c or an upstream pull that changed it. The post-
        # build copy step then ships a stale brotli.dll from the prior build.
        # `vcpkg remove` forces a clean re-install. Squelch the "package not
        # installed" exit on first build.
        & $vcpkgExe remove "brotli-iis:win-x64-avx2" "@$responseFile" 2>&1 | Out-Null
        $LASTEXITCODE = 0  # `remove` of a non-installed package is fine

        & $vcpkgExe install "brotli-iis:win-x64-avx2" "@$responseFile"
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
# stale DLL from a previous build, or worse — the brotli library's own
# brotli.dll (different ABI from what IIS expects).
$built = Join-Path $repoRoot 'out/vcpkg/install/win-x64-avx2/bin/brotli.dll'
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
