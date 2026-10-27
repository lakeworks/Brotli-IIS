# Brotli-IIS — IIS compression scheme plugin (local clone)

Native IIS module that adds `br` (brotli) as a compression scheme. Loads into `w3wp.exe`.

## Why we have it

Origin (IIS) currently only encodes `gzip`/`deflate`. Modern browsers prefer `br` (brotli). Adding native brotli at origin:
- Reduces origin→Bunny CDN bandwidth (~15-20% smaller than gzip on text/JS/CSS)
- Faster cache fills, lower egress costs
- May steer Bunny CDN's edge pipeline away from the zstd interop bug (when origin returns brotli for Chrome's `gzip, deflate, br, zstd` requests, Bunny doesn't enter the broken "client wanted zstd, origin returned identity" code path).

Full investigation: `./docs/iis-compression-and-bunny-zstd.md`.

## Upstream

- **Repo**: https://github.com/saucecontrol/Brotli-IIS
- **Maintainer**: Clinton Ingram (saucecontrol) — established .NET imaging maintainer
- **License**: MIT
- **Library**: Google brotli 1.2.1, vcpkg-managed with SHA512 verification (overlay port = vcpkg's own 1.2.1 port, `build/vcpkg/ports/brotli/`). The DLL links only `brotlienc` + `brotlicommon`, never the decoder, so decoder CVEs such as CVE-2026-111497 do not reach it.
- **Code review notes**: see top-level docs file (encoder-only, ~80 LoC plugin glue, no I/O/network/registry/subprocess)

## Local policy

- **No precompiled DLLs from upstream.** Always build from source via `build-x64.ps1`. Upstream binaries are unsigned (verified 2026-04-29) — building locally gives us supply-chain provenance.
- **AVX2 baseline** in our build (Intel Haswell+ / AMD Excavator+). **Measured on brotli 1.1.0 (2026-05-16, `iis-compression-bench` build matrix): AVX2 within 1–3% of SSE2 — no measurable gain.** The brotli encoder is dominated by entropy coding (range/Huffman). brotli 1.2 adds explicit SIMD for qualities 5–7 (tag matchers), but only SSE2, which every x64 build already has; nothing in the encoder is gated on AVX2, so AVX2 changes only scalar-codegen patterns that the auto-vectoriser may or may not exploit. We keep `/arch:AVX2` because (a) all our deployment targets are post-2017 silicon, (b) the upstream vcpkg port already uses `/GL` so adding `/arch:AVX2` is a one-line triplet override. **If you find yourself debating whether the overlay is worth the maintenance cost: it isn't, unless a benchmark on representative response bodies shows a non-trivial gain.** **Caveat**: if this DLL is ever deployed to a Hyper-V VM running in CPU compatibility mode, an older DR failover host, or an AWS/Azure SKU that masks AVX2 in the guest, w3wp.exe will crash on the first illegal instruction. Verify CPU compat before deploying off the canonical fleet.
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

Register the scheme in root `applicationHost.config`.

**Add the scheme to the existing `<httpCompression>` element** — don't replace the wrapper. The existing element registers `gzip`/`deflate` and the static/dynamic MIME-type tables; replacing it wipes them and breaks compression for every site on the server.

**Order matters: the `br` `<scheme>` line must precede the existing `gzip` and `deflate` `<scheme>` entries.** IIS evaluates the registered schemes in document order and serves the first one whose name matches a token in the request's `Accept-Encoding` header. Chrome sends `Accept-Encoding: gzip, deflate, br, zstd`; if `br` is registered after `gzip`, IIS picks `gzip` and the brotli pipeline is never invoked — the bandwidth + Bunny-CDN-zstd-bug-avoidance reasons for deploying this module are silently defeated. Place the `<scheme name="br" .../>` line above the existing `gzip` and `deflate` entries (or use `appcmd /+"[name='br',...]"` followed by `appcmd /-` + re-add of gzip/deflate to force order; or hand-edit the XML, accepting the lock-while-IIS-running caveat from the master doc's runbook).

```xml
<scheme name="br" dll="C:\Program Files\IIS\IIS Compression\brotli.dll"
        dynamicCompressionLevel="4" staticCompressionLevel="10" />
```

**Levels**: brotli supports 0–11; the IIS metabase schema for `staticCompressionLevel` constrains the value to 0–10 — using 11 risks IIS rejecting the config at load time and bringing down every brotli-eligible app pool. We use 10, the highest schema-allowed value.

**Caveat on `dynamicCompressionLevel`**: `dynamicCompressionLevel="4"` keeps per-request CPU modest for runtime-generated content, but brotli's cost is steeply non-linear and dynamic compression has **no size floor** — every dynamic response, tiny JSON included, pays the full encoder setup cost. Bench data shows brotli quality 9 taking tens of milliseconds on small payloads (~0.5 MB/s) — the steep upper end of the curve; quality 4 is materially cheaper but still pays the per-request encoder setup on every response. Keep `dynamicCompressionLevel` at 4 or below; prefer wiring this scheme to *static* compression (cacheable assets) and leaving dynamic responses to `gzip`, or restrict dynamic brotli to large body types via `<dynamicTypes>`. IIS has no minimum-dynamic-size key, so the quality cap is the only lever.

**Caveat on `staticCompressionLevel="10"`**: even at level 10, brotli encoding cost is high. A cache-busting query string (`?ver=1234567890`) or a non-cacheable response can pin a worker thread on encoding for tens or hundreds of milliseconds per request. Under attack-grade load this is a CPU-exhaustion vector. Either ensure `<httpCompression cacheControlHeader="..." />` is set so encoded responses are cached for repeated requests, or lower this to 8–9 if cache-miss ratios are non-trivial. Avoid 5–7 as a fallback without a benchmark first: from brotli 1.2 those levels run newer SIMD tag matchers that allocate up to 2 MiB more per response.

**If you see truncated `Content-Encoding: br` responses in production** (the browser logs `net::ERR_CONTENT_DECODING_FAILED`): do not expect a lower level to fix it. The encoder holds pending output internally and drains it over as many calls as IIS makes, so a small IIS output buffer never fails a stream. `BrotliEncoderCompressStream` returns `BROTLI_FALSE` (surfaced by the plugin as `E_FAIL`) only on API misuse, and an allocation failure never reaches the plugin at all: brotli's default `BROTLI_ENCODER_EXIT_ON_OOM` calls `exit()`, which terminates the w3wp.exe worker (look for a worker-process recycle/crash in the System event log, not for truncation). Look first at something between origin and browser (CDN, proxy, a module rewriting the body after compression). Source-verified against brotli 1.1.0 and 1.2.1 `c/enc/encode.c` + `c/enc/memory.{h,c}` (`docs/reviews/brotli-1.2.1-encoder-delta-*-2026-10-27.md`).

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

We track upstream `master` to stay current with brotli library security updates and supply-chain hygiene. **No local source modifications** — only the `build-x64.ps1` script and this CLAUDE.md are local additions — so that `git pull origin master` is always a clean fast-forward and any future contribution back to upstream stays trivially separable from our build/doc additions. **One exception (operator-approved 2026-10-27):** when we move the brotli library ahead of upstream, bump the `BROTLI_VERSION_*` lines in `src/CMakeLists.txt` to the library version, as upstream does with each of its own bumps, so the DLL's file version names the brotli it contains; expect a trivial conflict there when upstream next bumps.

Updating the vcpkg submodule (the brotli library is pulled via vcpkg, not as a top-level submodule):

1. `cd vcpkg && git fetch && git log <current>..origin/master` to review what changed in the vcpkg tooling itself.
2. Verify the brotli portfile + version pin we actually consume. **The build uses `--overlay-ports build/vcpkg/ports/` (see `build/vcpkg/response`), so the overlay's `build/vcpkg/ports/brotli/` overrides the submodule's `vcpkg/ports/brotli/`.** Updating only the submodule's port file leaves the overlay version in effect, and the rebuilt DLL still links against the overlay's pinned brotli release. To pick up an upstream brotli update:
    - `git diff --no-index -- build/vcpkg/ports/brotli/portfile.cmake vcpkg/ports/brotli/portfile.cmake` to see what the overlay locks down vs. what the submodule now offers. (Use `git diff --no-index`, not `diff -u`: in the repo's PowerShell workflow `diff` resolves to the `Compare-Object` alias, which has no `-u`.)
    - If you want the new version: copy the relevant fields (REF, SHA512, version-semver) from `vcpkg/ports/brotli/` into `build/vcpkg/ports/brotli/`.
    - Inspect the diff and the upstream release notes for any portfile-shape changes (vcpkg API drift, new patches) that need to be reflected in the overlay.
3. `git checkout <new-sha>` inside `vcpkg/`, then `cd .. && git add vcpkg build/vcpkg/ports/brotli && git commit` from the repo root.
4. Re-run `build-x64.ps1` and re-deploy. The post-build DLL inspection (size, exports) is the smoke test.
