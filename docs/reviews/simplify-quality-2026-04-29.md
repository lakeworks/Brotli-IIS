# Brotli-IIS — /simplify (quality lens) — 2026-04-29

> Captured by parent (agent ran in read-only Explore mode and couldn't write the file directly).

## Summary

Gate 1 (adversarial) successfully addressed 3 Critical and 5 Operational findings. The production-hardening branch now has correct error handling, environment variable restoration, path resolution, and well-justified documentation of the AVX2 baseline.

Quality review finds one straightforward output label error and opportunities to improve comment structure and documentation completeness. All findings are polish-class (P1–P2).

## Findings

### Q-1 — Duplicate "Built" label in final output; should be "Modified" or "Date"

**Files**: `build-x64.ps1:119-122`

**Observation**:
```powershell
Write-Host "Built: $($info.FullName)" -ForegroundColor Green
Write-Host "Size:  $($info.Length) bytes"
Write-Host "Built: $($info.LastWriteTime)"  # <- Should not say "Built"
```

Line 122 repeats the label "Built" where it should read "Modified" or "Date" to match the property being printed (`LastWriteTime`).

**Recommendation**: Change line 122 label from "Built:" to "Modified:".

**Priority**: P1

---

### Q-2 — "AVX2 reach" comment conflates two distinct concerns

**Files**: `build-x64.ps1:66-76`

**Observation**: The comment merges (1) HOW AVX2 flags reach the binary (triplet override, buildtree keying, no stale reuse) with (2) WHY we skip verification and keep AVX2 anyway (no SIMD in brotli encoder, perf curiosity, symmetry). These are independent topics and should be documentable separately for future maintainers.

**Recommendation**: Split into two comments with clearer topic boundaries.

**Priority**: P2

---

### Q-3 — File inventory incomplete: `brotli.rc.in` not listed in "Files" section

**Files**: `CLAUDE.md:72-79`

**Observation**: The "Files" section lists items under `src/` but omits `src/brotli.rc.in` (Windows resource template that embeds version info and copyright into the final DLL).

**Recommendation**: Add entry: `- \`src/brotli.rc.in\` — Windows resource template (DLL versioning, copyright)`.

**Priority**: P2

---

### Q-4 — "Upstream relationship" section could clarify intent behind no-source-modifications policy

**Files**: `CLAUDE.md:84-86`

**Observation**: The section states "No local source modifications" but doesn't restate why. The earlier Build section hints ("keeps the working tree merge-clean") but the policy intent isn't stated in the Upstream Relationship section where it belongs.

**Recommendation**: Add a sentence clarifying that source modifications are intentionally avoided to keep upstream merges simple and safe.

**Priority**: P2

---

## No findings in

- **Commit message quality**: Subjects follow `[type]: [subject]`; bodies clearly explain gate-1 findings.
- **Variable naming**: All variables clear and unambiguous.
- **Error handling consistency**: Both native-exe invocations have explicit `$LASTEXITCODE` checks; header comment enforces the rule for future maintainers.
- **Script structure and readability**: Logical 5-phase flow with Write-Host markers.
- **Deployment guidance**: Level constraints, CPU cost, and truncated-response recovery are all present and well-justified.

**Status**: No blockers. P1 + P2 items can be addressed in a follow-up polish commit.
