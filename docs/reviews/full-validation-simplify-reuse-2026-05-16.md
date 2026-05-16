---
status: findings
arc: full-validation
gate: 2-simplify
lens: reuse
repo: Brotli-IIS
critical: 0
operational: 0
polish: 2
---

# Gate-2 /simplify — reuse lens — Brotli-IIS full-validation

Scope: `05c7715..HEAD` on `production-hardening` (gate-1 follow-up commits).
Touched files reviewed: `build-x64.ps1`, `.gitignore`, `CLAUDE.md`, `readme.md`.
Review-artifact files in the range (`docs/reviews/full-validation-*`) are out of lens scope.

## Summary

Reuse posture is good. The gate-1 follow-ups did not introduce structural code
duplication: the rewritten vcpkg remove/verify block in `build-x64.ps1`
(commit 9164756) is a single linear sequence — two failure detectors that test
*different* surfaces (exit code vs on-disk metadata), not a copy-paste. No
repeated logic to consolidate there.

The one real reuse concern is **prose-fact restatement that can drift**: the
`readme.md` fork banner (commit 3344d9e) deliberately restates two facts that
already live in `CLAUDE.md`. Both are Polish — the restatement is defensible at
a fork boundary, but the desync risk is real and worth a one-line guard.

No Critical, no Operational. Two Polish findings below.

## Findings

### [P1] `readme.md:7` restates the `staticCompressionLevel` 0–10 cap fact already owned by `CLAUDE.md:55`

`readme.md:7` (new fork banner) carries the full fact:

> "the IIS metabase schema caps `staticCompressionLevel` at `10`; a value of
> `11` is rejected at config load and brings down every brotli-eligible app
> pool."

`CLAUDE.md:55` already owns the canonical statement of the same fact ("brotli
supports 0–11; the IIS metabase schema for `staticCompressionLevel` constrains
the value to 0–10 — using 11 risks IIS rejecting the config at load time and
bringing down every brotli-eligible app pool").

This is a deliberate duplication — the banner exists *because* the upstream
sample (`readme.md:50`) used to show `11`, and the banner steers readers to
`CLAUDE.md`. But once you've stated "see `CLAUDE.md`", restating the cap fact
inline re-creates the exact desync hazard the banner is trying to fix: a future
edit to the `CLAUDE.md` "Levels" line (e.g. wording change, or a schema-version
caveat) leaves `readme.md:7` silently stale, and `readme.md` is upstream-inherited
so the drift is harder to notice.

Fix shape (Polish, single line, reduces merge surface): drop the trailing
"Note that the IIS metabase schema caps..." sentence from `readme.md:7`. The
banner's first half already says "use the deployment sample in `CLAUDE.md`
rather than the one below" — that pointer is sufficient; the reader who follows
it gets the cap fact from the canonical home. Keep the banner pointing, not
re-explaining. This also *shrinks* the readme delta against upstream, which is
the right direction for an upstream-tracking fork.

If the team prefers to keep the inline fact as a load-bearing safety callout
(it is a "brings down every app pool" hazard, so a case exists), then leave it
but accept the duplication knowingly — in that case the fix is a no-op and this
finding is informational only. Recommended: drop it; the pointer carries it.

### [P2] `readme.md:7` restates the "build from source / unsigned binaries" policy already owned by `CLAUDE.md:24`

`readme.md:7` says: "build from source via `build-x64.ps1` (do **not** use the
releases-page binaries; they are unsigned)". `CLAUDE.md:24` is the canonical
home: "No precompiled DLLs from upstream. Always build from source via
`build-x64.ps1`. Upstream binaries are unsigned (verified 2026-04-29)".

Same drift class as [P1] — the `CLAUDE.md` line carries a dated verification
("verified 2026-04-29") that the readme paraphrase silently discards, so the two
are already not byte-equal and a future re-verification date bump won't
propagate.

Unlike [P1], this one is harder to delete cleanly: the banner's whole purpose is
to override the upstream readme's `releases page` recommendation
(`readme.md:44`, "Binaries are available on the releases page"), so *some*
"don't use the binaries" statement has to stay in the readme to do its job.

Fix shape (Polish): keep the steer but make it a pure pointer, not a
paraphrase — e.g. "...do not use the releases-page binaries below; this fork
builds from source (see `CLAUDE.md` → Local policy)." That preserves the
override function while making `CLAUDE.md` the single source for *why*
(unsigned, dated). Net effect: the only fact the readme asserts on its own is
"this fork builds from source", which cannot drift because it is a statement
about the fork's existence, not a mutable policy detail.

## Out-of-lens / not findings

- **`build-x64.ps1:20-21` vs `:98-99`** — the "vcpkg keys buildtrees by triplet
  name → forces a fresh compile, no stale-buildtree reuse" comment is duplicated
  near-verbatim in two places. This is *pre-existing* duplication (the diff in
  range only swapped em-dashes for `--` inside it, commit 63c792e); it was not
  introduced or restructured by the gate-1 follow-ups, so it is out of scope for
  a gate-2 review of `05c7715..HEAD`. Noting it only so a future full-file pass
  can decide: consolidating it is free (build-x64.ps1 is fork-only, no upstream
  merge cost), but it is genuinely two different explanatory contexts (header
  param doc vs inline at the build step), so leaving it is also defensible. Not
  actioned here.

- **`build-x64.ps1` rewritten remove/verify block (9164756)** — reviewed for
  repeated logic; clean. The two failure detectors are non-redundant (exit-code
  surface vs on-disk-metadata surface), and the comment explicitly justifies why
  both exist. No consolidation possible without losing a detector.

- **`.gitignore:4-8`** — new comment block is unique, no restated fact. Clean.

- **`CLAUDE.md:57` dynamic-compression caveat** — new prose, parallel in *shape*
  to the existing `:59` static caveat ("Caveat on ..." heading pattern) but the
  content is distinct (no size floor / non-linear cost vs cache-busting CPU
  exhaustion). Intentional parallel structure, not duplication. Clean.
