---
status: findings
arc: full-validation
gate: 4-review
repo: Brotli-IIS
critical: 0
operational: 0
polish: 2
---

# Brotli-IIS — gate-4 /review (final coherence) — full-validation arc

Scope: follow-up commits `05c7715..HEAD` on `production-hardening` (9 commits).
Final-coherence gate — NOT a fresh adversarial or simplify pass. Checked:
doc-vs-code drift, finding-close mismatches, tracker-vs-commit gaps, internal
contradictions, build-script integrity.

## Verification performed — clean

### build-x64.ps1 integrity
- `grep -nP '[^\x00-\x7F]' build-x64.ps1` → **no non-ASCII**. The em-dash
  regression (gate-1 [O2]) is fully reverted; all 5 sites (`8,9,21,44,99`) now
  carry `--`. No broken sentences.
- `[System.Management.Automation.Language.Parser]::ParseFile` → **PARSE OK**.

### Finding-close cross-check — all gate-1 Operational closed by the cited commit
- **[O1]** untracked/ungitignored overlay dirs → closed by `717fdfe`
  (`.gitignore` now carries `build/vcpkg-overlay-*/`). Confirmed live.
- **[O2]** em-dash parse-failure regression → closed by `63c792e`
  (5 substitutions; `grep` + parse confirm).
- **[O3]** silenced `vcpkg remove` failure → closed by `9164756`. The two-detector
  rewrite is live at `build-x64.ps1:153-178`: exit-code inspection with a
  benign-`not installed` swallow (`154-159`) AND the on-disk residual scan at the
  *corrected* shared path `out/vcpkg/install/vcpkg/info` (`169-178`). The blanket
  `$LASTEXITCODE = 0` is gone. Codex gate-1 [P2] (both runs) flagged the same
  wrong-metadata-path bug and is closed by the same commit.
- **[O4]** missing dynamic-quality caveat + invalid `11` in readme sample →
  closed by `3344d9e`. `readme.md:50` sample now reads `staticCompressionLevel="10"`;
  `CLAUDE.md:57` carries the new dynamic-compression caveat.

### Gate-2 Polish — disposition matches the commits
- quality [P1] (`.gitignore` comment named only `Set-Content`) → fixed `b93edd0`;
  comment now says "regenerates the directory and its triplet file", naming both
  writers without an inaccurate single-writer parenthetical. Confirmed live.
- quality [P2] (dynamic caveat's Q9 figure unanchored) → fixed `02c396e`;
  `CLAUDE.md:57` now frames Q9 as "the steep upper end of the curve" and adds
  "quality 4 is materially cheaper but still pays the per-request encoder setup".
- reuse [P1]/[P2] + quality [P3] (readme banner restates CLAUDE.md facts) →
  deferred no-action-by-design, recorded in `full-validation-followups-2026-05-16.md`
  with an explicit kept-by-design rationale. Defensible.

### Doc-vs-code agreement (per brief item 1)
- `.gitignore` comment vs glob: comment describes arch-specific overlay triplets
  regenerated each run; glob is `build/vcpkg-overlay-*/`. **Agree.**
- vcpkg remove/verify block comment (`build-x64.ps1:144-168`) vs the two-detector
  code (`153-178`): comment enumerates detector 1 = exit code with benign swallow,
  detector 2 = on-disk residue at the shared `vcpkg/info` path. Code matches
  exactly, including the `$tripletName`-scoped filename filter. **Agree.**
- CLAUDE.md dynamic caveat vs registration sample: caveat says "keep
  `dynamicCompressionLevel` at 4 or below"; sample at `CLAUDE.md:52` uses `4`.
  **Agree.**
- readme.md fork banner vs CLAUDE.md (gate-2 reuse-lens flagged drift risk):
  banner says schema caps `staticCompressionLevel` at `10`, `11` is rejected and
  "brings down every brotli-eligible app pool" — `CLAUDE.md:55` says the schema
  "constrains the value to 0–10 … using 11 risks IIS rejecting the config at load
  time and bringing down every brotli-eligible app pool". Same fact, consistent
  wording. **Currently AGREE** (the deferred-by-design drift *risk* is real but
  not yet realised).
- readme sample `staticCompressionLevel`: `readme.md:50` = `10`. Matches
  `CLAUDE.md:52` and the banner. **Agree.**
- readme banner "build from source / unsigned binaries" vs `CLAUDE.md:24`: both
  say build from source via `build-x64.ps1`, upstream binaries unsigned.
  **Agree** (the banner drops the dated "verified 2026-04-29" qualifier — that is
  the gate-2 reuse [P2] drift observation, knowingly deferred).

### Internal contradictions
None. No commit message claims a state the code/docs contradict.

---

## Polish

### [P1] Gate-3 followups doc does not enumerate or disposition the codex gate-1 `[P3]` (`diff -u` shell-safety) finding
- **Files**: `docs/reviews/full-validation-followups-2026-05-16.md` (gate-3 record);
  `docs/reviews/full-validation-codex-2026-05-16` (codex run 1).
- **Detail**: codex run 1 returned **two** items — `[P2]` (vcpkg metadata path,
  converges with adversarial [O3], closed by `9164756`) and `[P3]`:
  *"Use a PowerShell-safe portfile diff command — CLAUDE.md:93. When run from the
  repo's PowerShell workflow, `diff` resolves to the `Compare-Object` alias and
  `-u` is not a valid parameter."* The gate-3 followups doc header summarises
  codex as "0C/1O/1P, two convergent runs" and its `[-] Gate-1 Polish` section
  enumerates only the **five adversarial** Polish items (P1–P5). The codex `[P3]`
  is neither in the count narrative nor dispositioned anywhere. `CLAUDE.md:93`
  still carries the un-annotated `diff -u build/vcpkg/ports/brotli/portfile.cmake
  vcpkg/ports/brotli/portfile.cmake` — a maintainer running the documented
  procedure from the repo's stated PowerShell-7 workflow gets a `Compare-Object`
  parameter error. This is a tracker-vs-finding-close gap: a real (if minor)
  surfaced finding fell out of the gate-3 audit. Severity Polish — the finding
  itself is cosmetic (the procedure still works from Git Bash, which CLAUDE.md
  notes is the Bash-tool default), but an un-recorded surfaced finding is the
  kind of drift gate-4 exists to catch.
- **Fix shape**: either (a) add one line to `CLAUDE.md:93` labelling it a Git Bash
  command or switching to the shell-neutral `git diff --no-index --
  build/vcpkg/ports/brotli/portfile.cmake vcpkg/ports/brotli/portfile.cmake`, OR
  (b) add a `[-]` deferral line to `full-validation-followups-2026-05-16.md`
  recording the codex `[P3]` as a knowingly-deferred cosmetic item. (a) is the
  cleaner close — it is a single-line doc edit with no semantic change.

### [P2] Gate-3 followups doc count narrative is imprecise about which codex run produced which finding
- **File**: `docs/reviews/full-validation-followups-2026-05-16.md:11`.
- **Detail**: the header says "codex 0C/1O/1P, two convergent runs". The two
  codex docs each self-report `findings: C=0 O=1 P=1` in their YAML footer, but
  they are **not** the same two findings: `full-validation-codex-2026-05-16` =
  {metadata-path, `diff -u` shell-safety}; `full-validation-codex-fullbase-2026-05-16`
  = {metadata-path, gitignore-overlay}. Only the metadata-path finding is
  genuinely convergent across both runs; the other slot differs (shell-safety vs
  gitignore). Calling them "two convergent runs" and folding to a single
  "0C/1O/1P" understates the union — the actual codex surface is the
  metadata-path Operational plus *two* distinct Polish items, which is how [P1]
  above slipped through. Cosmetic bookkeeping imprecision, no code impact.
- **Fix shape**: optional — if [P1] is closed by amending the followups doc, also
  correct the line-11 summary to reflect the union (metadata-path O + 2 distinct
  P). Trivially folded in with the [P1] fix.

---

## Cross-cutting — gate-4 verdict

The arc is coherent. All four gate-1 Operational findings are closed by the
commits that claim to close them; both convergent codex metadata-path findings
are closed by the same `9164756`; gate-2 Polish dispositions (2 fixed, 3
deferred-by-design) match the commit log and the gate-3 record. build-x64.ps1
parses and is ASCII-clean. Docs and code agree across every pair the brief
flagged — including the readme-banner-vs-CLAUDE.md drift-risk pair, which
currently agrees.

The two Polish findings are bookkeeping gaps in the gate-3 followups doc, not
code or production-behaviour defects: one surfaced codex finding (`diff -u`
shell-safety) was never dispositioned, and the "two convergent runs" framing
papers over which run found what. No Critical, no Operational. Both Polish items
are trivially-fixable with a single-line `CLAUDE.md:93` edit plus a one-line
followups-doc amendment; recommend folding both in this session rather than
deferring, since the fix is smaller than the tracker entry.
