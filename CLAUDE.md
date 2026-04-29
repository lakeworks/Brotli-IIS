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
- **AVX2 baseline** in our build (Intel Haswell+ / AMD Excavator+). The brotli encoder is dominated by entropy coding (range/Huffman) which doesn't vectorise well — measurable speedup from AVX2 is <1% on encode workload. We keep `/arch:AVX2` for symmetry with the zstd-IIS build (where it does pay off ~2-5%) and because all our deployment targets are post-2017 silicon. **Caveat**: if this DLL is ever deployed to a Hyper-V VM running in CPU compatibility mode, an older DR failover host, or an AWS/Azure SKU that masks AVX2 in the guest, w3wp.exe will crash on the first illegal instruction. Verify CPU compat before deploying off the canonical fleet.
- **No AVX-512.** Marginal benefit on this encoder + server-side clock-throttling under sustained AVX-512 load on most Xeon Scalable / Zen 4 SKUs.
- **Window size is brotli's default (LGWIN=22, 4 MiB)**. Chrome accepts up to LGWIN=24; we don't override. Asymmetric vs zstd-IIS, where we explicitly cap windowLog at 23 to stay under Chrome's 8 MiB zstd-specific limit. **Don't "match" the zstd cap by raising brotli's window** — zstd's limit is decoder-imposed by Chrome; brotli's defaults are already inside the safe zone.

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

Add the scheme to the existing `<httpCompression>` element (don't replace the wrapper — the existing element registers gzip/deflate and the static/dynamic MIME-type tables that you need to keep):

```xml
<scheme name="br" dll="C:\Program Files\IIS\IIS Compression\brotli.dll"
        dynamicCompressionLevel="5" staticCompressionLevel="10" />
```

**Levels**: brotli supports 0–11; the IIS metabase schema for `staticCompressionLevel` constrains the value to 0–10 — using 11 risks IIS rejecting the config at load time and bringing down every brotli-eligible app pool. We use 10, the highest schema-allowed value.

`dynamicCompressionLevel="5"` is a balanced default for runtime-generated content (low CPU cost, ~80% of the compression ratio of higher levels).

**Caveat on `staticCompressionLevel="10"`**: even at level 10, brotli encoding cost is high. A cache-busting query string (`?ver=1234567890`) or a non-cacheable response can pin a worker thread on encoding for tens or hundreds of milliseconds per request. Under attack-grade load this is a CPU-exhaustion vector. Either ensure `<httpCompression cacheControlHeader="..." />` is set so encoded responses are cached for repeated requests, or lower this to 7-8 if cache-miss ratios are non-trivial.

**If you see truncated `Content-Encoding: br` responses in production** (Chrome falls back to identity, but the browser logs `net::ERR_CONTENT_DECODING_FAILED` first): `BrotliEncoderCompressStream` returned `BROTLI_FALSE` to the plugin and the plugin reported `E_FAIL` to IIS mid-stream. The most common cause at high quality levels is the encoder buffering more than IIS's per-call output buffer can drain in one pass. Drop `staticCompressionLevel` to 9, then 7, until it stops. The plugin doesn't differentiate "needs more output buffer" from "real error" — both surface as `E_FAIL`; lowering the level reduces the encoder's internal buffering pressure.

**Scheme registration is server-wide.** All sites with `urlCompression doStaticCompression="true"` become eligible for brotli. To limit to specific sites, use per-site `urlCompression` toggles in their respective `web.config`.

## Verification after deploy

```bash
# Direct origin probe with Chrome's Accept-Encoding
curl -sS -I -H "Accept-Encoding: gzip, deflate, br" https://your-site.example.com/wp-content/themes/oceanwp/assets/js/theme.min.js
# Expect: Content-Encoding: br
```

Then re-test via CDN to verify the Bunny zstd bug behavior.

## Files

- `src/brotli.c` (~58 LoC) — `Compress`, `CreateCompression`, `DestroyCompression`
- `src/brotli.h` (~25 LoC) — Init/DeInit/Reset stubs + includes
- `src/brotli.def` — DLL exports
- `src/brotli.rc.in` — Windows resource template (DLL versioning, copyright)
- `src/CMakeLists.txt` — upstream build config
- `build/vcpkg/...` — vcpkg overlay (custom triplets, brotli-iis port, shared.cmake)
- `build-x64.ps1` — our AVX2 build script (lakeworks fork)

## Upstream relationship

We track upstream `master`. No local source modifications — only the `build-x64.ps1` script and this CLAUDE.md are local additions. Run `git pull origin master` to update; build script remains in working tree (not committed upstream).
