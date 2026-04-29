# Brotli-IIS — IIS compression scheme plugin (local clone)

Native IIS module that adds `br` (brotli) as a compression scheme. Loads into `w3wp.exe`.

## Why we have it

Origin (IIS) currently only encodes `gzip`/`deflate`. Modern browsers prefer `br` (brotli). Adding native brotli at origin:
- Reduces origin→Bunny CDN bandwidth (~15-20% smaller than gzip on text/JS/CSS)
- Faster cache fills, lower egress costs
- May steer Bunny CDN's edge pipeline away from the zstd interop bug (when origin returns brotli for Chrome's `gzip, deflate, br, zstd` requests, Bunny doesn't enter the broken "client wanted zstd, origin returned identity" code path).

Full investigation: `D:\CC\docs\iis-compression-and-bunny-zstd.md`.

## Upstream

- **Repo**: https://github.com/saucecontrol/Brotli-IIS
- **Maintainer**: Clinton Ingram (saucecontrol) — established .NET imaging maintainer
- **License**: MIT
- **Library**: Google brotli 1.1.0, vcpkg-managed with SHA512 verification
- **Code review notes**: see top-level docs file (encoder-only, ~80 LoC plugin glue, no I/O/network/registry/subprocess)

## Local policy

- **No precompiled DLLs from upstream.** Always build from source via `build-x64.ps1`. Upstream binaries are unsigned (verified 2026-04-29) — building locally gives us supply-chain provenance.
- **AVX2 baseline** in our build (Intel Haswell+ / AMD Excavator+). Acceptable since target servers are all post-2017.
- **No AVX-512.** Brotli's encoder is mostly entropy coding, not SIMD-amenable; AVX-512 also causes server downclock under sustained load on some SKUs.

## Build

```powershell
.\build-x64.ps1
# Output: out/brotli.dll
```

Prereqs: VS 2022 Build Tools with C++ workload, Git.

The script sets up an AVX2-enabled vcpkg overlay triplet and builds via vcpkg without modifying upstream files. This keeps the working tree merge-clean against upstream.

## Deployment

DLL goes to `C:\Program Files\IIS\IIS Compression\brotli.dll` (alongside the existing Microsoft IIS Compression schemes — see `kimboslice99/zstd-IIS` issue #1 for path convention).

Register the scheme in root `applicationHost.config`:

```xml
<httpCompression>
  <scheme name="br" dll="C:\Program Files\IIS\IIS Compression\brotli.dll"
          dynamicCompressionLevel="5" staticCompressionLevel="11" />
</httpCompression>
```

`staticCompressionLevel="11"` is brotli max — fine for static assets cached at edge. `dynamicCompressionLevel="5"` is a balanced default for runtime-generated content.

**Scheme registration is server-wide.** All sites with `urlCompression doStaticCompression="true"` become eligible for brotli. To limit to specific sites, use per-site `urlCompression` toggles in their respective `web.config`.

## Verification after deploy

```bash
# Direct origin probe with Chrome's Accept-Encoding
curl -sS -I -H "Accept-Encoding: gzip, deflate, br" https://deepvector-studio.com/wp-content/themes/oceanwp/assets/js/theme.min.js
# Expect: Content-Encoding: br
```

Then re-test via CDN to verify the Bunny zstd bug behavior.

## Files

- `src/brotli.c` (~58 LoC) — `Compress`, `CreateCompression`, `DestroyCompression`
- `src/brotli.h` (~25 LoC) — Init/DeInit/Reset stubs + includes
- `src/brotli.def` — DLL exports
- `src/CMakeLists.txt` — upstream build config
- `build/vcpkg/...` — vcpkg overlay (custom triplets, brotli-iis port, shared.cmake)
- `build-x64.ps1` — our AVX2 build script (mstickers-local)

## Upstream relationship

We track upstream `master`. No local source modifications — only the `build-x64.ps1` script and this CLAUDE.md are local additions. Run `git pull origin master` to update; build script remains in working tree (not committed upstream).
