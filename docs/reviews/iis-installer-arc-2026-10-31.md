# IIS installer + public release (2026-10-31)

Branch `iis-installer-2026-10-31`, base `production-hardening` @ 1f585f6.

## Operator request

Verbatim, 2026-10-31: "do we have an easy way to deploy Brotli compression on other vms? This repo is public or private (ours?)", then, after the proposal of an install script plus a GitHub release carrying the DLL and its checksum: "ok proceed", and "no use Claude Code please" / "I mean Claude" (implementer = Claude, not codex), then "don't use agent... so the switch will be ok :p" (the main session writes it, no subagent, across an account switch).

## Constraints

- Operator 2026-10-31: "we deploy a binary, not going for the build on a remote vm!" / "hosts are identical". Target VMs only download the released DLL, verify its hash and run the install script; the single build happens on the build host.

- Public repository: no host names, IP addresses, host paths, customer or site names in any tracked file, commit message or release asset.
- The released DLL must not embed the build host's path. Measured 2026-10-31: the DLL built at `.claude/worktrees/brotli-121/out/brotli.dll` (the one deployed) carries the full build-tree PDB path. Fix: link with `/PDBALTPATH:%_PDB%` so only `brotli.pdb` is embedded.
- The script must run on Windows PowerShell 5.1 as well as PowerShell 7 (a fresh Windows Server VM has only 5.1). Use `appcmd.exe` for IIS configuration; no module or package install.
- System-configuration changes happen only when the operator runs the script; restarting the WWW service only with an explicit switch.

## Plan

1. `build-x64.ps1`: add `/PDBALTPATH:%_PDB%` to the generated overlay triplet's release linker flags (both LTO variants). One commit.
2. `install-iis.ps1` at the repo root (next to `build-x64.ps1`), one commit. Behaviour:
   - Parameters: `-DllPath` (required), `-ExpectedSha256` (required), `-DynamicLevel` (default 4, range 0–11), `-StaticLevel` (default 10, range 0–10 — IIS schema limit), `-ProxyFriendly` (sets `noCompressionForProxies="false"` and `staticCompressionIgnoreHitFrequency="true"` on `<httpCompression>`), `-RestartWww` (stop + start W3SVC at the end), `-VerifyUrl` (optional; after a restart, a `br`-only request must answer `Content-Encoding: br`), `-Rollback` (restore the most recent backup this script made and say a WWW restart is needed). `[CmdletBinding(SupportsShouldProcess)]` so `-WhatIf` prints every change and makes none.
   - Preflight, failing closed with a plain message: elevated; 64-bit OS; IIS installed (`%windir%\system32\inetsrv\appcmd.exe` present); static and dynamic compression modules present in `<globalModules>`; CPU reports AVX2 (`IsProcessorFeaturePresent(40)`), since the DLL is built with `/arch:AVX2` and an AVX2-less CPU crashes w3wp.exe; DLL SHA-256 equals `-ExpectedSha256`; DLL is an x64 PE exporting `CreateCompression`, `Compress`, `DestroyCompression`; DLL FileVersion read for the target name.
   - Install: `appcmd add backup` with a name `brotli-iis-<yyyyMMdd-HHmmss>`; copy the DLL to `%ProgramFiles%\IIS\IIS Compression\brotli-<FileVersion major.minor.patch>.dll` (create the folder if absent; if the target exists with a different hash, stop; same hash = skip copy); if a `br` scheme exists, repoint its `dll` and levels; else add it at the start of the scheme collection (`[@start,...]`) so it precedes `gzip`/`deflate`; if `br` exists but is not first, report it and move it first (remove + re-add at `@start`); never touch other schemes, MIME tables or site settings. Re-running with the same inputs changes nothing.
   - End: print the resulting scheme list in order, the backup name, the rollback command, and — without `-RestartWww` — that the new DLL takes effect only after a WWW service restart (Microsoft scheme reference) and the exact commands.
3. `readme.md`: a short "Install on IIS" section (download release asset, verify hash, run the script, verify with curl), placed in our fork's own section. One commit.
4. Release (after review and merge): rebuild with step 1, run the bench round-trip + IIS-ABI conformance suite against the rebuilt DLL, check the DLL holds no host path, then publish GitHub release `brotli-iis-1.2.1` on `lakeworks/Brotli-IIS` with `brotli.dll` + `SHA256SUMS`.

## Deviations from the plan (implementation, 2026-10-31)

- No PE-machine or export-table check: the SHA-256 pin to the published checksum already fixes the exact binary, so a structural check adds code without adding a guarantee.
- `-StaticLevel` accepts 0–11, not 0–10. The build host's `%windir%\system32\inetsrv\config\schema\IIS_schema.xml` declares `staticCompressionLevel` and `dynamicCompressionLevel` as `uint` with no validation range (read 2026-10-31), and `src/brotli.c` accepts 0–11, so CLAUDE.md's "the IIS metabase schema constrains the value to 0–10" does not hold on that host. Default stays 10 (operator 2026-10-31: "so we could change the default?", then "yes let's keep the default"); the CLAUDE.md sentence needs correcting in its own commit.

- Rollback redesigned after review round 4 (three fix rounds on the rollback/activation surface each bred new Operational findings: rollback order, partial-failure state, pending activation across runs). The `-Rollback` mode and its state file are removed: the install writes an undo note before any change, whose command reinstalls the previous DLL and levels through the same install path; a full revert is `appcmd restore backup`. `-VerifyUrl` requires `-RestartWww`, so no cross-run activation tracking is needed. A br registered between other schemes is moved first (plan step 2), and no other scheme is touched.

## Out of scope

URL Rewrite rule that prioritises `br` (separate open operator decision); `master` vs `production-hardening` default-branch question; ARM64/x86 builds.

## Review

Production-touching install script for a native module loaded into w3wp.exe: lanes per `.claude/project.conf` (codex, grok, agy) on the candidate SHA. No Claude reviewer lane: the operator asked for no agents during an Anthropic account switch ("don't use agent... so the switch will be ok :p").

## Review brief

Review the diff `production-hardening..<target SHA>`: `install-iis.ps1` (new), `build-x64.ps1` (linker flag), `readme.md`, `CLAUDE.md` ("Levels" paragraph). The plan and constraints are in this document; the deployment rules the script must follow are in `CLAUDE.md` section "Deployment".

Judge, with evidence (file:line, and Microsoft or PowerShell documentation where a claim depends on it):
- Does `install-iis.ps1` do what its help text and this plan say, on Windows PowerShell 5.1 and PowerShell 7? Look at native-argument quoting to `appcmd.exe`, `appcmd` command syntax and exit codes, `-WhatIf`/`ShouldProcess` coverage of every change, idempotence on re-run, the undo note and whether its command really restores the previous configuration, partial-failure states (what the server is left with if a step fails midway), and the `-VerifyUrl` check.
- Can it damage an IIS server's configuration: other schemes, MIME tables, site settings, a DLL in use?
- Does `/PDBALTPATH:%_PDB%` reach the DLL link step through the vcpkg triplet and remove the build path from the DLL, without affecting the static-library archiver?
- Is every factual claim in the changed documentation correct?
- Anything in a public repository that identifies a host, path, site or person.

Severity: Critical / Operational / Polish. If you could not run your tools, say `result: inconclusive` and name the failed call.
