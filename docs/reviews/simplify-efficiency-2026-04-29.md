# Brotli-IIS — /simplify (efficiency lens) — 2026-04-29

## Summary

The Brotli-IIS fork is already remarkably lean. Gate 1 addressed all Critical+Operational findings; the production-hardening branch incorporates fixes for the AVX2 reach verification gap, env-var leakage, DLL fallback search, and schema-level cap at 10. The local additions are minimal: two files only (build-x64.ps1 + CLAUDE.md, 206 lines combined); no source modifications.

**Build-time cost**: vcpkg overlay triplet forces a fresh compile of brotli + plugin per build (AVX2 triplet name differs from upstream win-x64), adding ~30-60 seconds. No obvious reuse left on the table given the triplet isolation by design.

**Binary size**: the DLL ships ~350-420 KB (x64, release, static-linked brotli 1.1.0 + IIS plugin glue). No dead code removal opportunities visible; vcpkg already excludes debug tools.

**Doc length**: 84 lines in CLAUDE.md. Reads as load-bearing: all sections are essential. No redundancy vs. the master iis-compression-and-bunny-zstd.md; they serve different purposes (fork-specific guidance vs. incident context).

**AVX2 economics**: Gate 1 documented the <1% measured perf delta on the encoder. The build now carries clear commentary on why it's kept (symmetry with zstd-IIS, post-2017 fleet guarantee). No build-side improvement available if the policy stands.

---

## Findings

### E-1 — Potential for drop-AVX2 simplification (defer architectural decision)

**Files**: build-x64.ps1 (lines 38-77), CLAUDE.md (lines 25-26)

**Observation**: The current approach layers a custom win-x64-avx2.cmake triplet on upstream win-x64.cmake, adding overhead:
- vcpkg isolates buildtrees by triplet name, forcing a fresh brotli+plugin compile every time (no cross-triplet cache reuse).
- The triplet file creation, env-var set/restore, and path management add ~5% to script complexity.
- Gate 1 documented that brotli's encoder is entropy-coding-dominated with <1% measurable AVX2 gain.

However, Gate 1 also documented the deliberate trade-off: keep AVX2 for symmetry with zstd-IIS (2-5% gain there) and post-2017 fleet guarantee. CLAUDE.md now carries a clear CPU-compatibility caveat.

**Recommendation**: No action this cycle. The AVX2 policy is architectural, not an efficiency oversight. If the business decision shifted to drop AVX2, the simplification path is:
1. Replace the custom triplet with vcpkg install "brotli-iis:win-x64".
2. Remove the win-x64-avx2.cmake file and overlay-dir logic.
3. Delete the "AVX2 reach" commentary.

This would save ~30 lines of PowerShell. But it is a forking/alignment decision vs. zstd-IIS, not a hidden cost.

**Priority**: P1+ (architectural, not efficiency alone)

---

### E-2 — Doc prose: truncated-br-response explanation can be compressed

**Files**: CLAUDE.md (lines 59-65)

**Observation**: The truncated-br-response block (6 sentences, ~70 words) explains the symptom, cause (encoder buffering), and fix (drop level). The master iis-compression-and-bunny-zstd.md also mentions this symptom briefly. A reader hitting both docs will see the explanation twice.

**Recommendation**: Compress to a one-liner with cross-reference. Current is 70 words; suggested is 20:

Old: "**If you see truncated Content-Encoding: br responses in production** (Chrome falls back to identity, but the browser logs net::ERR_CONTENT_DECODING_FAILED first): BrotliEncoderCompressStream returned BROTLI_FALSE to the plugin and the plugin reported E_FAIL to IIS mid-stream. The most common cause at high quality levels is the encoder buffering more than IIS's per-call output buffer can drain in one pass. Drop staticCompressionLevel to 9, then 7, until it stops..."

New: "**If you see truncated Content-Encoding: br responses**: drop staticCompressionLevel from 10 to 9 to 7 until it stops. See the master compression doc for technical details."

Operational action is clear; readers who want theory go to master doc.

**Priority**: P2 (clarity/brevity, not functional)

---

### E-3 — vcpkg brotli has no feature trimming available

**Files**: build/vcpkg/ports/brotli/vcpkg.json, portfile.cmake (line 16)

**Observation**: The brotli vcpkg port uses default feature set. Google's brotli library offers no vcpkg.json feature toggles to disable decompressor or tools. The portfile does exclude debug tools, but the decoder is statically linked regardless because brotli bundles encoder+decoder in one CMakeLists.

Linker strips unused decoder code; the ~350-420 KB DLL size is near-optimal. No trimming knobs exist upstream.

**Recommendation**: No action. Binary size is as lean as vcpkg allows.

**Priority**: P2 (informational)

---

### E-4 — Build script is sequential; no parallelism available

**Files**: build-x64.ps1 (lines 31-102)

**Observation**: Steps are:
1. Bootstrap vcpkg (~10-20s, one-time).
2. Write overlay triplet (~1ms).
3. vcpkg install (~30-60s, dominates total).
4. Locate & copy DLL (~100ms).

Each depends on the prior. No opportunity for parallelization. Env-var save/restore pattern is correct and standard PowerShell.

**Recommendation**: No optimization available. Build time is dominated by vcpkg compilation, not PowerShell overhead.

**Priority**: P2 (informational)

---

### E-5 — vcpkg submodule is stale but not a build-time issue

**Files**: .gitmodules

**Observation**: vcpkg pinned to 2024-01-12 (~16 months old). Gate 1 noted this doesn't affect brotli 1.1.0 (immutable + SHA512 verified) but flagged that future bumps (e.g., to 1.2.0, Oct 2025) would require submodule update.

Build-time impact: negligible. vcpkg.exe bootstraps once; stale portfiles don't slow subsequent builds.

**Recommendation**: Document in CLAUDE.md that if brotli is bumped to 1.2.0 or later, vcpkg submodule must be updated to a version that includes the new portfile. Procedural note, not current inefficiency.

**Priority**: P2 (maintenance, not efficiency)

---

### E-6 — Build script lacks elapsed-time instrumentation

**Files**: build-x64.ps1 (throughout)

**Observation**: Script uses "[1/5]..." milestones but no elapsed-time counters. Hard to tell if 40-second build is dominated by bootstrap, compile, or copy. For CI/CD tracing, lack of timing makes regression detection difficult (e.g., vcpkg cache breakage goes undetected).

**Recommendation**: Add timing counter: $buildStart = Get-Date at line 13, then "Build time: $((Get-Date) - $buildStart).TotalSeconds seconds" at end. Low-complexity observability win.

**Priority**: P2 (observability)

---

## Summary table

| Area | Status | Finding | Priority |
|---|---|---|---|
| AVX2 policy | Gate-1 gaps addressed | Defer simplification unless Ops decides | P1 |
| Doc prose | Tight | Compress truncated-br block (70→20 words) | P2 |
| Binary size | Optimal for upstream | No trimming knobs available | P2 |
| Build speed | Sequential | No parallelism; vcpkg dominates | P2 |
| Submodule age | Known | Only matters if version bumped | P2 |
| Observability | Functional | Add elapsed-time counter | P2 |

---

## Conclusion

The Brotli-IIS fork is already efficient. Gate 1 addressed all Critical+Operational gaps. Gate 2 finds no hidden build-time, binary-size, or doc-length costs. The only architectural decision worth revisiting is AVX2 vs. no-AVX2 (30-line simplification available if policy flips), but that is a business choice, not an efficiency oversight.

Recommendations are polish-level: tighter prose (E-2, P2), build-time visibility (E-6, P2), and documenting future submodule-bump procedure (E-5, P2). None are blocking.

Local additions remain merge-clean against upstream. No source modifications. Ready for production deployment pending gate-1 operational checklist (verify 64-bit app pools, inventory per-site compression overrides, verify IIS version accepts staticCompressionLevel=10).
