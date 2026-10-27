# brotli 1.2.1 vs 1.1.0 — correctness, throughput and ratio (2026-10-27)

Decision evidence for the brotli 1.2.1 upgrade arc (`brotli-1.2.1-arc-2026-10-27.md`).

## Builds compared

All four built by `build-x64.ps1`, static CRT, LTO on; plugin source identical apart from the file-version stamp.

| Variant | brotli | Size (bytes) | SHA-256 (prefix) |
|---|---|---:|---|
| 1.1.0 AVX2 (deployed today) | 1.1.0 | 875,520 | `f425679ff54c176e` |
| 1.1.0 SSE2 | 1.1.0 | 872,448 | `e772c77957272953` |
| 1.2.1 AVX2 | 1.2.1 | 904,704 | `a20d7f5ab3478579` (pre-stamp build, file version still reads 1.1.0) |
| 1.2.1 SSE2 | 1.2.1 | 901,632 | `6838f16e1fb12675` |

The LTO-off 1.2.1 builds are ~900 KB (1.1.0 LTO-off: ~3.56 MB) — 1.2's static-table rework removes most of the LTO size gap.

## Correctness

`iis-compression-bench` branch `brotli-121-roundtrip-2026-10-27`: new `BrotliRoundTripTests` (IIS-style chunked feed + drain to S_FALSE, decoded by .NET's BrotliDecoder, byte-identical; qualities 0..11; text fixtures, empty, 1 byte, zeros, 1 MiB incompressible, 4 MiB repetitive, 9 MiB past-window; hostile 1/7/4093-byte chunks with 1- and 13-byte output buffers; 8 concurrent contexts) plus `ConformanceTests` and `EncoderParamsTests`.

- 1.1.0 AVX2: 478/478 passed.
- 1.2.1 AVX2: 478/478 passed.

## Compression ratio

Compressed sizes through the IIS scheme ABI (64 KiB buffers), text fixtures, qualities 4/7/9/10: **identical byte counts for all four builds in every cell** (each build re-measured in its own process to rule out loader reuse of a same-named DLL). Example: real homepage HTML 173,758 B → q4 33,901 / q10 28,790 for both versions.

## Throughput

BenchmarkDotNet `BrotliIisFixtureBenchmark` (warmup 3, iterations 5), two interleaved rounds in opposite variant order, geometric mean of per-round means, on a shared Zen 5 host (12 logical cores) under concurrent load: per-cell relative stddev median 12 %, max 30 %. Differences under ~10 % are within noise.

Geometric mean over the six text fixtures (time per compress; negative = 1.2.1 faster):

| Quality | 1.2.1 vs 1.1.0, AVX2 | 1.2.1 vs 1.1.0, SSE2 | 1.2.1 SSE2 vs AVX2 |
|---:|---:|---:|---:|
| 4 (deployed dynamic) | −4.5 % | +7.9 % | +10.4 % |
| 7 | **+38.8 %** | **+38.3 %** | −4.0 % |
| 9 | −0.8 % | −3.3 % | −2.7 % |
| 10 (deployed static) | +0.7 % | +1.0 % | +6.3 % |

Reading:
- Deployed levels 4 and 10 on the AVX2 build: parity within noise.
- **Quality 7 is consistently ~40 % slower in 1.2.1** on every fixture (all ≤ 174 KB, i.e. web-sized). It is the level that switches to the new SIMD tag matcher (H58), whose per-encoder tag array (2 MiB at q7) is allocated and set up for every response; on small bodies that setup outweighs the faster matching. This backs the runbook change steering the static fallback to 8–9, never 5–7.
- AVX2 vs SSE2 on 1.2.1: no difference beyond noise at 7/9; AVX2 ahead at 4 and 10. Keep AVX2 (deployment-target caveat in CLAUDE.md unchanged).

## Not measured

- Ratio via the bench's own `ratio` runner: it aborts with an access violation inside the IIS `gzip.dll` encoder path before reaching brotli (a bench defect unrelated to this upgrade, recorded in the bench arc).
- Peak memory per request; a quiet-host re-run for tighter error bars.
