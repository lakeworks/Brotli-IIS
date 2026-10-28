# brotli 1.2.1 upgrade arc (2026-10-27)

Branch `brotli-1.2.1-2026-10-27`, base `production-hardening` @ 77ca50e.

## Operator request

Verbatim, 2026-10-27: "please look into the 1.2.1 and whether it can be used to serve the web?" then "and we want to keep the high level of optimisation/speed and also security we had. So proceed. Use GPT 6.1 Sol to help too." DLL version label: operator chose "Bump to 1.2.1" at the popup the same day.

## Plan

1. Replace the overlay brotli port (1.1.0) with microsoft/vcpkg's own 1.2.1 port, verbatim, hash cross-checked (ed63069).
2. Independent source audits of the 1.1.0 -> 1.2.1 encoder delta: GPT-6.1 Sol and Opus (f22191b).
3. Docs: library line, runbook corrections the audits surfaced, AVX2 rationale, the operator-approved version-label exception (f03690e, fa39215, 96b1f2d, f1d93d0).
4. Build all four variants (AVX2/SSE2 x LTO on/off); round-trip + conformance tests (iis-compression-bench branch `brotli-121-roundtrip-2026-10-27`); A/B throughput and ratio vs the deployed 1.1.0 build (`brotli-avx2-lto`, sha256 f425679f...).
5. Deploy to IIS only on the operator's explicit go (system-config change).

## Review brief

Review the diff `production-hardening..HEAD` of this repository: a native IIS compression-scheme DLL (src/brotli.c, loaded into w3wp.exe on a production web server) moving from brotli 1.1.0 to 1.2.1 by replacing the vcpkg overlay port under `build/vcpkg/ports/brotli/`, plus a file-version stamp in `src/CMakeLists.txt` and documentation in `CLAUDE.md`, `build-x64.ps1` comments and `docs/reviews/`.

Judge, with file:line evidence:
- Supply chain: does the overlay port pin exactly the upstream 1.2.1 release (REF, SHA512) and apply only patches that are safe for this build? Anything the old port did that the new one silently drops (e.g. the removed fix-arm64ec.patch) that matters for the x64 triplets `build-x64.ps1` generates?
- Build: will `build-x64.ps1`'s overlay triplets, the `brotli-iis` port and `src/CMakeLists.txt` (`find_package(Brotli NAMES unofficial-brotli)`, targets `unofficial::brotli::brotlienc` / `brotlicommon`) still link only the encoder and common libraries, with the same flags (static CRT, /GL + /LTCG, optional /arch:AVX2)?
- Documentation accuracy: every factual claim added to CLAUDE.md and build-x64.ps1 in this diff (library scope, the truncated-response runbook paragraph, the level-fallback advice, AVX2 rationale, the version-label exception) — is each true against the brotli 1.2.1 source (fetch https://github.com/google/brotli at tag v1.2.1 if you need it) and the code in this repo? A wrong operational instruction is a finding.
- The two audit documents in docs/reviews/: any claim in them that the source contradicts.

Severity: Critical (production break, security exposure, wrong deploy instruction with outage potential) / Operational / Polish. If you could not run your tools, say `result: inconclusive` and name the failed call.
