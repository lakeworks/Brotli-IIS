# Brotli-IIS — /simplify (reuse lens) — 2026-04-29

## Summary

The Brotli-IIS fork has minimal local additions (build-x64.ps1 + CLAUDE.md, zero source modifications), and the reuse lens finds one actionable consolidation opportunity without blocking findings.

The sibling zstd-IIS fork shares parallel structure and deployment guidance. Both projects' CLAUDE.md files contain redundant scheme-registration and deployment-procedure documentation that is now superseded by the expanded "Per-DLL deployment runbook" section in the master doc (./docs/iis-compression-and-bunny-zstd.md). Project CLAUDE.md files can safely reference this single source of truth rather than duplicating the runbook.

No duplicate code within Brotli-IIS. The build script (build-x64.ps1) is compact (122 lines) and straightforward — no extracted helpers needed.

---

## Findings

### R-1 — Deployment procedure duplicated across Brotli-IIS and zstd-IIS CLAUDE.md files

**Files**:
- ./Brotli-IIS/CLAUDE.md:40-72 (Deployment + Verification sections)
- ./zstd-IIS/CLAUDE.md:59-99 (Deployment + Verification sections, with zstd-specific details)
- ./docs/iis-compression-and-bunny-zstd.md:194-258 (master "Per-DLL deployment runbook")

**Observation**:

Both project CLAUDE.md files contain overlapping guidance:
- "Add the scheme to the existing <httpCompression> element, don't replace the wrapper" (Brotli-IIS:46, zstd-IIS:65)
- DLL placement path and naming convention (Brotli-IIS:42, zstd-IIS:61)
- "Scheme registration is server-wide" caveat (Brotli-IIS:61, zstd-IIS:89)
- Verification via curl with Accept-Encoding header (Brotli-IIS:66-71, zstd-IIS:93-99)

The master doc already contains a comprehensive "Per-DLL deployment runbook" (lines 194–257) that covers all these points in a single, detailed procedure suitable for both modules. The current project CLAUDE.md sections are shorter summaries that repeat the same core guidance.

**Redundancy pattern**:
- Brotli-IIS and zstd-IIS have independent, parallel descriptions of the same deployment steps.
- The master doc's runbook was expanded to subsume this guidance.
- The two project CLAUDE.md files now have overlapping short-form versions of content in the master doc.

**Recommendation**:

Consolidate by replacing both projects' Deployment and Verification after deploy sections with brief references to the master doc. The project-specific compression-level tables stay in each project CLAUDE.md. The common procedure (config backup, appcmd, pool recycle, event log monitoring) lives in the master doc.

Example for Brotli-IIS CLAUDE.md:

  ## Deployment

  Follow the Per-DLL deployment runbook in ./docs/iis-compression-and-bunny-zstd.md
  (lines 194-258). It covers DLL placement, scheme registration via appcmd, config backup,
  pool recycling, and post-deployment verification for both Brotli-IIS and zstd-IIS.

  For Brotli-IIS specifically:
  - DLL path: C:\Program Files\IIS\IIS Compression\brotli.dll
  - Scheme config (add to existing <httpCompression> element):
      <scheme name="br" dll="C:\Program Files\IIS\IIS Compression\brotli.dll"
              dynamicCompressionLevel="5" staticCompressionLevel="10" />
  - Levels: brotli supports 0-11, but IIS metabase schema limits staticCompressionLevel
    to 0-10. Use 10 as the ceiling.

  **Truncated responses under load**: if you see truncated Content-Encoding: br responses
  in production, the encoder's output buffer is undersized for the current quality level.
  Drop staticCompressionLevel to 9, then 7, until it stops. See the runbook for the appcmd
  syntax to update the config.

  **Scheme registration is server-wide.** All sites with compression enabled become eligible.
  To limit to specific sites, use per-site <urlCompression> toggles in web.config.

**Benefits**:
- Single source of truth (easier maintenance, consistency).
- Project CLAUDE.md files focused on project-specific details.
- Master doc already more comprehensive (config backup, event log monitoring, rollback).
- Future runbook updates automatically benefit both projects.

**Priority**: P1

---

### R-2 — "Local policy" duplicates AVX2 rationale across both projects

**Files**:
- ./Brotli-IIS/CLAUDE.md:22-27 (Local policy)
- ./zstd-IIS/CLAUDE.md:29-33 (Local policy)
- ./docs/iis-compression-and-bunny-zstd.md:164-172 (SIMD / AVX2 / AVX512 considerations)

**Observation**:

Both projects' CLAUDE.md files explain the AVX2 build baseline and why not AVX-512. The master doc's "SIMD / AVX2 / AVX512 considerations" section already provides comprehensive per-library performance data (brotli <1%, zstd 2-5%, AVX-512 marginal + downclock risk).

The current project sections are encoder-specific but overlap in rationale.

**Recommendation**:

Keep Local policy sections in both CLAUDE.md files (project-specific), but cross-reference the master doc for SIMD rationale rather than re-explaining.

Example simplification for Brotli-IIS:

  ## Local policy

  - No precompiled DLLs from upstream. Always build from source via build-x64.ps1.
    Upstream binaries are unsigned — building locally provides supply-chain provenance.
  - AVX2 baseline (Intel Haswell+ / AMD Excavator+). See the master doc's
    "SIMD / AVX2 / AVX512 considerations" section for per-library performance details.
    Caveat: if deployed to a Hyper-V VM in CPU compatibility mode, an older DR failover
    host, or an AWS SKU that masks AVX2, w3wp.exe will crash on first compression call.
    Verify CPU compat before deploying off the canonical fleet.
  - No AVX-512. Marginal benefit on this encoder + server downclock risk.
  - Window size: brotli default LGWIN=22 (4 MiB). Chrome accepts up to LGWIN=24.
    Differs from zstd-IIS, which caps windowLog=23 for Chrome's 8 MiB zstd limit.

**Benefits**:
- Reduces redundancy while preserving project context.
- Common guidance lives once (master doc), evolves in one place.
- Project CLAUDE.md files stay focused on what's unique to each project.

**Priority**: P2 (lower urgency than R-1; this is rationale, not procedure).

---

### R-3 — No intra-project code duplication

**Files**: ./Brotli-IIS/build-x64.ps1 (122 lines)

**Observation**:

Reviewed for repeated code blocks:
- Lines 31-36: vcpkg bootstrap (single use)
- Lines 38-62: triplet overlay creation (single use)
- Lines 64-102: vcpkg install with env var save/restore (single use)
- Lines 104-116: DLL locate and copy (single use)

No three+ similar patterns. Try/finally for env cleanup is a best-practice pattern, not duplication.

**Recommendation**: None. Build script is already minimal and clear.

**Priority**: N/A

---

## No findings

- Within-project duplication: None found.
- Stdlib helpers: PowerShell cmdlets are appropriate. No open-coded logic warranting extraction.
- Cross-fork code reuse: Different toolchains (vcpkg vs CMake+msbuild) and libraries. Code-level reuse minimal. Duplication is in documentation (R-1, R-2), not code.

---

## Actions summary

ID | Action | Priority
---|---|---
R-1 | Consolidate Deployment sections in both CLAUDE.md to reference master runbook | P1
R-2 | Trim redundant SIMD rationale, cross-reference master doc | P2

No blocking issues. Both are documentation-only and optional polish per global CLAUDE.md standard.

---

*Gate 2/4 (reuse lens) of cadence chain. No critical or operational findings.*
