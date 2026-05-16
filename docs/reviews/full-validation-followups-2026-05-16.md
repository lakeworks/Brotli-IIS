---
status: deferred-items
arc: full-validation
repo: Brotli-IIS
date: 2026-05-16
gate: 3-docs-tracker
---

# Brotli-IIS full-validation — gate-3 docs+tracker record

Gate-1 (adversarial 0C/4O/5P + codex 0C/1O/1P, two convergent runs) and
gate-2 (/simplify, 3 lenses, 0C/0O/5P) ran on Brotli-IIS. The fork delta is
confirmed build-script + docs only — `src/` is byte-identical to upstream. All
Operational findings were addressed this session as `adversarial follow-up:` /
`simplify follow-up:` commits (`05c7715..HEAD`).

## Gate-3 self-audit

- `multi-vantage-required: no` — the arc touched `build-x64.ps1`, `.gitignore`,
  `CLAUDE.md`, `readme.md`: build-script + docs only, no service-identity /
  kernel / FSCTL / ABI surface (§Delegation triggers a–g all negative).
- `skip-mini-adversarial: gate-2 fixes are a .gitignore comment and a CLAUDE.md
  doc clause — no import-time call site, no guard/validator reshape, no
  cross-file flatten.`
- INTROSPEC: no mental-model shift warranting an entry.
- Rule sync: no `§NN` spec rules in this fork; none cited or changed.

## [-] Deferred Polish — gate-2 /simplify

Gate-2 returned 0C/0O/5P. Two were fixed (`.gitignore` comment writer-naming,
the dynamic-caveat quality-9 framing). Three are deferred no-action-by-design:

- reuse [P1] / quality [P3]: the `readme.md` fork banner restates the
  `staticCompressionLevel` 0–10 cap fact that `CLAUDE.md` owns. **Kept by
  design** — the banner is a deliberate safety callout sitting directly above
  a config sample; the hazard ("11 brings down every app pool") warrants the
  inline warning even at the cost of a duplicated fact. A pure "see CLAUDE.md"
  pointer would be ignored by a reader pasting the sample below it.
- reuse [P2]: the banner's "build from source / unsigned binaries" steer
  paraphrases `CLAUDE.md:24`. **Kept** — the banner must override the upstream
  readme's "releases page" recommendation, so some "don't use the binaries"
  statement has to live in `readme.md`; "they are unsigned" is a one-word
  reason, not a drift-prone paraphrase.

## [-] Gate-1 Polish — upstream-inherited / informational (no action)

The five gate-1 adversarial Polish items are all upstream-owned or procedural,
none fork-introduced:

- [P1] `src/brotli.c` flush-buffer / S_OK-vs-S_FALSE contract subtlety —
  upstream-owned code; `git pull` must stay clean (CLAUDE.md policy). No change.
- [P2] `readme.md` is wholly upstream and contradicts `CLAUDE.md` in places
  (releases-page install vs build-from-source) — partially addressed by the
  gate-1 fork banner; the rest is upstream prose left intact by policy.
- [P3] vcpkg submodule advanced without a recorded `git log` tooling-delta
  review. *Trigger:* record the delta review in the commit body next time the
  vcpkg submodule moves (CLAUDE.md already prescribes the step).
- [P4] `azure-pipelines.yml` is upstream's dead CI (Azure feed the fork can't
  reach). Harmless; deletion vs keep-for-merge-cleanliness is a judgment call,
  left as-is per the "keep upstream files" policy.
- [P5] the prior production-hardening branch's adversarial/codex transcripts
  were deliberately excluded from `docs/reviews/`. Auditability observation
  only; this full-validation arc's docs are committed in full.

## Cross-repo followup

- The em-dash-in-`.ps1` parse bug has now regressed twice (zstd-IIS, then
  Brotli-IIS). Discipline is not closing it — a mechanical guard (a pre-commit
  / CI lint rejecting non-ASCII in `*.ps1`) is the durable fix. This is a
  meta-level change (`~/.claude/` hooks or a per-repo CI step), tracked here as
  a cross-repo followup rather than actioned in this arc.
