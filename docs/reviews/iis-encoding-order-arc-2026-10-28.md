# IIS encoding-order doc correction (2026-10-28)

Branch `iis-encoding-order-doc-2026-10-28`, base `production-hardening` @ 263fbfa.

## Operator request

Verbatim, 2026-10-28: "proceed" — continuing the follow-ups listed after the brotli 1.2.1 arc closed, one of which was that the runbook's "IIS serves the first registered scheme" statement looked inaccurate.

## Plan

1. Correct the CLAUDE.md "Order matters" paragraph so it states what was observed on the live server: registration order decides fresh compressions; for cached static files IIS serves the first cached copy in the client's `Accept-Encoding` order.
2. One codex review, then merge into production-hardening and push.

## Review brief

Review the diff `production-hardening..HEAD` (one documentation paragraph in `CLAUDE.md`, section Deployment, "Order matters").

Judge, with evidence:
- Is every factual claim in the new paragraph consistent with Microsoft's IIS documentation (`<httpCompression>`, `<scheme>`, static compression cache behaviour) and with the probe it cites (on a live IIS 10 server, four never-requested static files answered `br` to `gzip, deflate, br, zstd`; after one `gzip`-only request, the same header was answered `gzip`; a `br`-only request still got `br`)? Flag any claim that goes beyond that evidence.
- Does the paragraph still give a correct, actionable deployment instruction (register `br` before `gzip`/`deflate`)?
- Anything in the rest of CLAUDE.md that the new paragraph now contradicts.

Severity: Critical / Operational / Polish. If you could not run your tools, say `result: inconclusive` and name the failed call.
