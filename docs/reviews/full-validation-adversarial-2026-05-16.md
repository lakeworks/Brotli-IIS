---
status: findings
arc: full-validation
gate: 1-adversarial
repo: Brotli-IIS
critical: 0
operational: 4
polish: 5
---

# Brotli-IIS — full-repo adversarial validation (gate 1/4)

## Phase 1 classification

- **Scope**: entire `lakeworks/Brotli-IIS` working tree. Fork delta = 8 commits, `692e569~1`→`HEAD`.
- **Host profile**: build host = Zen 5 (Ryzen 7 9700X). Deploy target = IIS `w3wp.exe` on the prod fleet. The DLL loads into a long-lived multi-threaded server process; a defective DLL takes down every brotli-eligible app pool.
- **Fork-claim verification (per brief)**: `git diff --stat 692e569~1..HEAD -- src/ CMakeLists.txt` is **empty**. `src/*.c|.h|.def|.rc.in` and `src/CMakeLists.txt` are byte-identical to the upstream fork point (last `src/` touch is upstream `bed336a release v1.1.0`). The CLAUDE.md "build script + docs only, no source changes" claim **holds**. `src/brotli.c` is still reviewed below for deployment risk per brief item 3, but none of its findings are fork-introduced — they are upstream-inherited and informational.
- **Probe categories in scope**: build-script correctness, supply-chain (vcpkg), external-API contract (IIS scheme ABI), hermetic-vs-real-OS, docs-drift.

## Summary — top 3

1. **[O1] The generated overlay triplet dirs are untracked AND ungitignored.** `build/vcpkg-overlay-{avx2,sse2}/` show as `??` in `git status`. They are pure build scratch (regenerated every run by `Set-Content`) — a clean checkout has no problem, but right now they pollute `git status`, risk being `git add -A`'d into a commit, and contradict the script's own "regenerated each run" design. Decide: gitignore them.
2. **[O2] The em-dash parse-failure bug that commit `0c2c32f` fixed has been reintroduced.** Commit `05c7715` (later, the arch-param commit) added 5 new em-dash characters (U+2014) into `build-x64.ps1` comments. This is the exact bug class `0c2c32f`'s commit message says "would surface as soon as [vcvarsall] is fixed". The fork has regressed its own fix.
3. **[O3] `vcpkg remove` swallows *all* stderr including catastrophic failures**, and the on-disk verify only covers one of two short-circuit layers. A `vcpkg.exe`-missing / bootstrap-corrupt / triplet-parse failure on the `remove` call produces no signal — the script proceeds straight to `install`, which then either short-circuits on a stale package or fails with a confusing downstream error.

---

## Operational

### [O1] Generated overlay triplet dirs are untracked and not gitignored — `git status` pollution + accidental-commit risk
- **Probe**: build-script correctness / hermetic-vs-real-OS.
- **Files**: `.gitignore` (only `.vs`, `out`); `build/vcpkg-overlay-avx2/win-x64-avx2.cmake`, `build/vcpkg-overlay-sse2/win-x64-sse2.cmake`; `build-x64.ps1:66,90-91`.
- **Failure mode**: `build-x64.ps1:66` does `New-Item -Force` on `$overlayDir` and `:91` writes `$tripletPath` with `Set-Content`. The content is *fully derived* from `$Arch` every run — it is build scratch, not config. But `.gitignore` does not cover `build/vcpkg-overlay-*`, so `git status` permanently reports two `??` dirs. Concrete failure: a future `git add -A` (common in this multi-arc session model) commits machine-generated triplet files; they then drift from what the script would generate (e.g. after a script edit to `$tripletContent`), and a reader trusts a stale tracked `.cmake` that the build never actually reads. The decision the brief asks for: **gitignore them**, not track them. Rationale — (a) they are 100% regenerated, so tracking gives zero reproducibility benefit and guarantees drift; (b) the build's correctness depends on the *script* producing them, never on a checked-in copy; (c) the sibling `build/vcpkg/triplets/win-x64.cmake` (the upstream-tracked triplet) is the thing that IS legitimately tracked — the overlays are deliberately separate precisely so they stay out of the upstream-clean tree.
- **Fix shape**: add `build/vcpkg-overlay-*/` to `.gitignore`. Optionally also `out/vcpkg/` is already covered by the `out` entry — confirmed fine.

### [O2] Em-dash parse-failure bug reintroduced into `build-x64.ps1` after commit `0c2c32f` fixed it
- **Probe**: build-script correctness / docs-drift (regression of an own fix).
- **File**: `build-x64.ps1:8, 9, 21, 44, 99` — five U+2014 EM DASH characters in comment lines (`grep -nP '[^\x00-\x7F]'` confirms).
- **Failure mode**: commit `0c2c32f` ("replace em-dashes with ASCII so the script actually parses") states the root cause: *"PowerShell loads the .ps1 via the active console codepage, not UTF-8, so em-dashes get mangled into garbage and the parser blows up before any build step starts."* That fix replaced every `—` with `--`. The **later** commit `05c7715` (arch-param) re-introduced 5 em-dashes in the new comment block it added (lines 8-9, 21, 44, 99). On a host whose console codepage is not UTF-8 (cp437/cp1252 — the default on stock Windows Server, which is exactly this fleet), the script fails to parse before `[1/5]` prints. The earlier RCA noted the brotli build "hadn't tripped this in our test because it failed earlier on a missing vcvarsall.bat" — i.e. this bug is currently *masked* by an unrelated prereq gap and will surface the moment that prereq is satisfied. The fork has regressed a fix it explicitly committed.
- **Fix shape**: replace the 5 em-dashes in `build-x64.ps1` comments with `--`. Mechanical-trigger candidate: a lint/pre-commit hook rejecting non-ASCII in `*.ps1` (the bug has now bitten twice across the zstd-IIS + Brotli-IIS siblings — discipline alone is not closing it).

### [O3] `vcpkg remove` failure is fully silenced; on-disk verify covers only the brotli-iis layer, not a remove-tool failure
- **Probe**: build-script correctness / supply-chain.
- **File**: `build-x64.ps1:150-161`.
- **Failure mode**: line 150 runs `& $vcpkgExe remove ... 2>&1 | Out-Null` then line 151 hard-sets `$LASTEXITCODE = 0`. The comment justifies this ("exit code is unreliable here; we check on disk below"). But the on-disk check at 155-161 only fires `if (Test-Path $vcpkgInfoDir)` — i.e. it detects *residual installed packages*, not a *failed-to-run remove*. Failure scenario: `vcpkg.exe` is present but the overlay triplet has a syntax error, or the response file path is wrong, or vcpkg itself crashes. `remove` exits non-zero, prints the real error to stderr — and `2>&1 | Out-Null` discards it, `$LASTEXITCODE = 0` erases the signal. If `$vcpkgInfoDir` does not exist yet (first-ever build, or a prior build that never reached install), the verify block is skipped entirely and the script proceeds to `install` with the operator having seen *zero* indication that `remove` failed. The subsequent `install` then either (a) short-circuits on a stale package the failed `remove` left behind — shipping a stale DLL, the exact failure mode the whole remove/verify dance exists to prevent — or (b) fails with a confusing secondary error far from the root cause. The brief's own probe ("overlay file written but build reads a cached triplet" / "partial builds") lands here.
- **Fix shape**: capture `remove` output to a variable instead of `Out-Null`; on non-zero exit, inspect the output — a benign "package not installed" message is fine to swallow, anything else should `throw` with the captured text. Do not blanket-zero `$LASTEXITCODE`. Alternatively keep the zero but make the on-disk verify *unconditional*: if `$vcpkgInfoDir` is absent that is itself fine, but the verify should not be the *only* failure detector for the remove step.

### [O4] No dynamic-quality cap — and the scheme cannot impose one; deploy docs warn but the bench's "Q9 unusable for dynamic" finding is not reflected in the registration sample
- **Probe**: external-API contract (IIS scheme ABI) / docs-drift.
- **Files**: `src/brotli.c:22-58` (the `Compress` ABI export); `CLAUDE.md:57,59`; `readme.md:48,68-72`.
- **Failure mode**: the brief asks whether the scheme caps the quality it uses for *dynamic* compression. It **cannot** — and structurally never could. `Compress` receives `compression_level` as an `IN INT` parameter from IIS (`brotli.c:30`) and the only thing it does with it is range-check `BROTLI_MIN_QUALITY..BROTLI_MAX_QUALITY` (0..11) then `BrotliEncoderSetParameter(..., BROTLI_PARAM_QUALITY, compression_level)`. The plugin is a pure pass-through; the effective dynamic quality is whatever `dynamicCompressionLevel` is set to in `applicationHost.config`. So the cap question reduces to docs. Status of the docs: `CLAUDE.md:52,57` registers `dynamicCompressionLevel="5"` and calls it "a balanced default ... low CPU cost" — but the bench data the brief cites (Q9 ≈ 27-60 ms on small payloads, ≈ 0.5 MB/s) shows brotli is steeply non-linear and even moderate quality is expensive on tiny dynamic bodies. `CLAUDE.md:59` does have a CPU-exhaustion caveat, but it is filed under `staticCompressionLevel="10"` only; there is **no** equivalent warning that `dynamicCompressionLevel` should be kept low (≤4) or that dynamic compression should be scoped to large bodies via `<dynamicTypes>` / a minimum-size threshold. Worse: `readme.md:48` (the upstream-inherited sample) registers `dynamicCompressionLevel="5"` *and* `staticCompressionLevel="11"` — 11 exceeds the IIS schema cap of 10 that `CLAUDE.md:55` explicitly warns brings down every app pool. The two docs in the same repo contradict each other on a config value that can crash production.
- **Fix shape**: (a) in `CLAUDE.md`, add an explicit dynamic-compression caveat: brotli at any quality is costly per-request on small dynamic bodies; keep `dynamicCompressionLevel` at 4 or below, set a `dynamicCompressionMinSize` (IIS has no native key — note that dynamic compression has no size floor and tiny JSON responses pay full encoder setup cost), and prefer wiring this scheme to *static* compression only. (b) Reconcile `readme.md:48` — either annotate it as upstream-sample-do-not-copy or correct the `staticCompressionLevel="11"` to `10` with a pointer to `CLAUDE.md:55`. Leaving an `11` in a registration snippet a maintainer might paste is the live hazard.

---

## Polish

### [P1] `Compress` flush-buffer / `S_OK`-vs-`S_FALSE` contract is upstream-inherited and subtle — worth a code comment, not a code change
- **File**: `src/brotli.c:50-57`.
- **Note**: when IIS calls with `input_buffer_size == 0` (end-of-stream), `op = BROTLI_OPERATION_FINISH`. The return-value line `return input_buffer_size || !BrotliEncoderIsFinished(encoderState) ? S_OK : S_FALSE;` relies on IIS re-calling `Compress` with a fresh output buffer whenever `S_OK` is returned and the encoder is not finished. If IIS's per-call output buffer is too small to drain the encoder in one pass, the loop continues correctly — but the plugin reports `E_FAIL` (line 51) on a *genuine* `BrotliEncoderCompressStream` false, with no way to distinguish "needs more output room" from "real error". `CLAUDE.md:61` already documents this exact symptom and the level-downgrade workaround. No fork bug — flagging only because the brief asked for a whole-file deployment-risk read. Not actionable as code (upstream-owned, `git pull` must stay clean per CLAUDE.md:87).

### [P2] `readme.md` is wholly upstream and now contradicts `CLAUDE.md` in several places
- **File**: `readme.md` (entire file is upstream-inherited).
- **Note**: beyond the `staticCompressionLevel="11"` issue rolled into [O4], `readme.md` describes a binaries-from-releases-page install ("Binaries are available on the releases page", lines 42, 62-63) which directly contradicts `CLAUDE.md:24` ("No precompiled DLLs from upstream. Always build from source"). A maintainer reading `readme.md` first could deploy an unsigned upstream binary. Polish not Operational because `CLAUDE.md` is the authoritative local doc and the brief treats readme as upstream-tracked; but a one-line banner at the top of `readme.md` pointing to `CLAUDE.md` for local policy would remove the trap.

### [P3] vcpkg submodule advanced (`640ec4f`) but pin-integrity rests entirely on git submodule SHA — no independent verification artifact
- **Probe**: supply-chain.
- **File**: `.gitmodules`, submodule pin `8097e8d34cd45f7a5b1f5d90c92be2198e3d712f` (`2026.03.18-302-g8097e8d34c`).
- **Note**: the submodule pin is a 40-hex git SHA, which is content-addressed and tamper-evident *as a git object* — that is genuine integrity. The actual brotli *source* is pulled by `build/vcpkg/ports/brotli/portfile.cmake` via `vcpkg_from_github(REPO google/brotli REF v1.1.0 SHA512 6eb280...)` — a real SHA512 content pin. So supply-chain provenance is structurally sound. The gap is procedural, not a defect: commit `640ec4f` advanced the submodule but there is no recorded `git log <old>..<new>` review of the vcpkg-tooling delta (CLAUDE.md:91 prescribes this step). Per `./CLAUDE.md` package-install discipline, a vcpkg-tooling advance is a supply-chain event. Polish severity because the consumed brotli port is pinned by SHA512 regardless of the submodule tooling version, so the blast radius of an unreviewed tooling bump is limited to vcpkg.exe behavior, not the shipped encoder bytes. Suggest: record the tooling-delta review in the commit body next time the submodule moves.

### [P4] `azure-pipelines.yml` is dead/foreign CI — points at upstream's Azure DevOps NuGet feed, never runs for this fork
- **File**: `azure-pipelines.yml:11` (`vcpkgNuGet: https://pkgs.dev.azure.com/saucecontrol/...`).
- **Note**: the file is upstream's CI, wired to `saucecontrol`'s private Azure DevOps package feed and NuGet auth. In the `lakeworks` fork it cannot run (no Azure pipeline bound, no feed access) and builds `win-arm64ec` / `win-x86` triplets the fork's `build-x64.ps1` does not produce. It is harmless dead weight, but a maintainer could mistake it for the fork's CI. Either delete it (the fork has no CI) or add a one-line comment that the fork builds via `build-x64.ps1` only. Keeping upstream files for merge-cleanliness is the stated policy (CLAUDE.md:87) so deletion is a judgment call — flagging, not mandating.

### [P5] `b2e4908` commit body documents that adversarial/codex/security review transcripts were deliberately excluded from `docs/reviews/`
- **File**: commit `b2e4908`, `docs/reviews/` (only `review-`, `simplify-{efficiency,quality,reuse}-` present).
- **Note**: not a code issue — auditability observation. The gate-1/gate-4 cadence for the prior production-hardening branch produced adversarial + codex + security-pass docs; `b2e4908`'s body states they were withheld because they "referenced downstream deployment specifics not appropriate for an upstream-tracking public-fork repo". That is a defensible call (this fork may flip public), but it means the `docs/reviews/` trail for the hardening branch is incomplete — a future reviewer cannot see what the adversarial pass found, only the curated /simplify + /review outputs. This current review doc partially closes that gap for the full-validation arc. No action; noted so the gap is on record.

---

## Cross-cutting note — no Critical findings

The fork delta is genuinely "build script + docs only" as claimed. `src/` is byte-identical to upstream; the IIS scheme ABI (`CreateCompression`/`Compress`/`DestroyCompression`/`Reset`/`Init`/`DeInit`, `brotli.def` exports) is unmodified and the upstream contract is sound (NULL-passthrough to `BrotliEncoderCreateInstance` is intentional, `E_FAIL` on encoder-create failure is correct, range-check on `compression_level` is present). No production-behavior, security, or data-loss defect is fork-introduced. The four Operational findings are real reliability/auditability gaps (a regressed parse fix, an untracked-scratch hygiene gap, a silenced-failure window in the build script, and a docs contradiction that could crash an app pool) and should all be addressed this session per cadence §Review-findings-discipline. Polish defers to tracker.
