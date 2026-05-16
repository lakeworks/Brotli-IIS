---
status: findings
arc: full-validation
gate: 2-simplify
lens: quality
repo: Brotli-IIS
critical: 0
operational: 0
polish: 3
---

# Brotli-IIS — gate-2 /simplify, quality lens

Scope: gate-1 follow-up commits `05c7715..HEAD` on `production-hardening`. Touched
non-doc-artifact files: `build-x64.ps1`, `.gitignore`, `CLAUDE.md`, `readme.md`.
Polish on a correct base — gate-1 Operational findings already fixed in this range.

## Verification performed

- **Em-dash → `--` replacements**: `grep -nP '[^\x00-\x7F]' build-x64.ps1` returns
  nothing. All five reintroduced em-dashes are gone; the rewritten sentences read
  cleanly (`8`, `9`, `21`, `44`, `99`). No broken sentence. **Clean.**
- **vcpkg remove/verify comment vs code** (`build-x64.ps1:144-168`): the new
  comment accurately describes the two-detector logic — detector 1 = exit-code
  with benign `not installed` swallow (matches `if ($LASTEXITCODE -ne 0)` +
  `-notmatch 'not installed'` at `154-159`); detector 2 = on-disk residual check.
  The shared-info-path comment (`161-168`) correctly states metadata lives at
  `out/vcpkg/install/vcpkg/info` (NOT per-triplet) — confirmed: `build/vcpkg/response`
  carries `--x-install-root`, which is what makes the shared `vcpkg/info` dir the
  real location. Comment matches code. **Clean.**
- **`.gitignore` comment**: `build/vcpkg/triplets/` exists and is tracked
  (`win-x64.cmake` etc.) — the "upstream-tracked triplet … stays" claim is
  accurate. **Clean.**
- **No dead code introduced.** The old `$installRoot` intermediate variable was
  removed when the path was corrected — no orphan left behind. **Clean.**

## Polish

### [P1] `.gitignore` comment cites `Set-Content` but the script uses two writers — minor imprecision
- **File**: `.gitignore:5`
- **Detail**: comment says `build-x64.ps1` "regenerates these from `$Arch` on
  every run (`Set-Content`)". The triplet *file* is written by `Set-Content`
  (`build-x64.ps1:91`), but the overlay *directory* is created by
  `New-Item -ItemType Directory -Force` (`build-x64.ps1:66`), and the gitignore
  pattern `build/vcpkg-overlay-*/` targets the directory. Naming only `Set-Content`
  slightly under-describes what makes the dir scratch. Trivial.
- **Fix shape**: drop the parenthetical `(Set-Content)` — "regenerates these from
  `$Arch` on every run" already carries the point — or widen it to
  "(New-Item + Set-Content)".

### [P2] CLAUDE.md dynamic/static caveats both cite "tens of milliseconds" — the dynamic caveat's bench figure is unanchored relative to the new readme/CLAUDE deployment sample
- **File**: `CLAUDE.md:57`
- **Detail**: the new dynamic-compression caveat says "Bench data shows brotli
  quality 9 taking tens of milliseconds on small payloads (~0.5 MB/s)". It then
  advises keeping `dynamicCompressionLevel` "at 4 or below" and the registration
  sample (`CLAUDE.md:52`) uses `4`. The figure is for quality **9**, but the
  recommendation is quality **4** — a reader cannot tell from this text whether
  quality 4 is cheap or also costs "tens of ms". The caveat proves brotli is
  steeply non-linear (good), but the one concrete number is for a quality the
  doc explicitly tells you not to use, so it slightly over-warns about the
  recommended setting. Not a contradiction — quality-9 cost legitimately motivates
  the cap — but the internal logic would be tighter if the number were tied to
  the recommended level or explicitly framed as "the high end of the curve".
- **Fix shape**: optional — append a clause like "(quality 4 is materially
  cheaper, but still pays per-request encoder setup with no size floor)" so the
  cited figure reads as the upper bound it is, not the expected cost at the
  recommended level. No behaviour change.

### [P3] readme fork-banner duplicates the `staticCompressionLevel` cap rationale already in CLAUDE.md — mild redundancy
- **File**: `readme.md:7`
- **Detail**: the new lakeworks fork banner is clear and accurate, and pointing a
  readme-first reader at `CLAUDE.md` is the right move. But its last sentence
  re-states the full `staticCompressionLevel`-capped-at-10 / "11 brings down every
  app pool" rationale, which `CLAUDE.md:55` already owns as the authoritative
  copy. Since the banner's whole purpose is "see `CLAUDE.md` for policy", inlining
  one specific policy detail invites the two copies to drift (e.g. if the schema
  cap is ever re-examined). The banner already corrected the sample's `11`→`10` on
  line 50, so the load-bearing fix is in place regardless.
- **Fix shape**: optional — trim the banner's final sentence to a pointer
  ("…and note the `staticCompressionLevel` cap documented in `CLAUDE.md`") rather
  than reproducing the rationale. Keeps one source of truth. Defensible to leave
  as-is if the intent is that the readme stand alone for a reader who never opens
  CLAUDE.md — judgment call, hence Polish.

## Cross-cutting

No Critical, no Operational. The follow-up commits are quality-clean: comments
match the code they describe, the em-dash regression is fully reverted with no
broken sentences, no dead code, no internal contradiction in CLAUDE.md (the new
dynamic caveat and the existing static caveat are consistent and complementary —
both warn about per-request CPU cost, neither contradicts the other or the
registration sample). All three Polish items are presentation refinements with no
behaviour impact; safe to defer to tracker if not trivially folded in.
