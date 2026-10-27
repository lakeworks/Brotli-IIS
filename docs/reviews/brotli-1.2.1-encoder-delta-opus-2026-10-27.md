# brotli 1.1.0 -> 1.2.1 encoder delta: security + performance audit (2026-10-27)

Scope: read-only source audit of `google/brotli` `v1.1.0`, `v1.2.1` and `master`, limited to what the
plugin links (`brotlienc` + `brotlicommon`) and its call pattern (`src/brotli.c:7-57`). Nothing was
built or run; claims come from `git show/diff/log`; unprovable ones are marked **UNVERIFIED**.

Plugin parameters as the encoder sees them: only `BROTLI_PARAM_QUALITY` is set
(`src/brotli.c:40`), so `lgwin` = 22 (`encode.c:684`), `mode` = generic, no dictionary attached,
`stream_offset` = 0, `size_hint` = 0 until the first `EncodeData`, where `UpdateSizeHint` sets it to
`min(unprocessed + available_in, 1<<30)` (`encode.c:1594-1607`, `:1684`). Build: MSVC x64, no
`BROTLI_*` defines (`build/vcpkg/ports/brotli/portfile.cmake` passes only `-DBROTLI_DISABLE_TESTS=ON`;
upstream `CMakeLists.txt:125-134` globs `c/enc/*.c`, so `static_init_lazy.cc` is never compiled).

**Topology fact that frames question 3:** `v1.2.1` (2026-10-21) is a release branch cut from `v1.2.0`
(2025-10-27, merge-base `028fb5a`) carrying only two commits: `b418fa8` (decoder: `c/dec/decode.c`,
`decode.h`) and `db24a98` (version bump). `git diff --stat v1.2.0 v1.2.1 -- c/` touches no encoder or
common file, so **the 1.2.1 encoder is byte-identical to the 1.2.0 encoder**, and every `master`
commit since 2025-10-27 is absent from 1.2.1.

## Verdict

**1.2.1's encoder is at least as safe as 1.1.0's for this plugin.** No new reachable memory-safety
defect, info leak into responses, hang, truncation or invalid-stream route was found. The stream
state machine the plugin drives is unchanged. The only substantive new matching code (the SIMD-tag
hashers H58/H68) runs only at qualities 5-7, not at the deployed 4 and 10.

Findings: Critical 0 · Operational 1 · Polish 5.

## 1. Memory safety (v1.1.0 -> v1.2.1, c/enc, c/common, c/include)

### Hasher selection per quality (MSVC x64, plugin parameters)

`platform.h:527-543` defines `BROTLI_TZCNT64 = _tzcnt_u64` for MSVC x64 (non-ARM64EC), so
`platform.h:648-649` sets `BROTLI_MAX_SIMD_QUALITY 7` (`_M_X64` is defined). `ChooseHasher`
(`quality.h:156-207`), with lgwin = 22 (the `lgwin <= 16` -> H40/41/42 branch and the `lgwin > 24` ->
H35/H55/H65 remap are both unreachable):

| q | 1.2.1 (size_hint < 1 MiB / >= 1 MiB) | 1.1.0 | changed matcher code? |
|---|---|---|---|
| 0, 1 | no hasher: `BrotliEncoderCompressStreamFast` (`encode.c:1635-1638`) | same | no (refactors only) |
| 2 | H2 | H2 | DCHECK + comment only |
| 3 | H3 | H3 | DCHECK + comment only |
| 4 (dynamic) | H4 / H54 (`quality.h:160-161`) | H4 / H54 | DCHECK + comment only (`hash_longest_match_quickly_inc.h`) |
| 5, 6, 7 | **H58 / H68** (`quality.h:168`, `:180`) | H5 / H6 | **new files** `hash_longest_match_simd_inc.h`, `hash_longest_match64_simd_inc.h` |
| 8, 9 | H5 / H6 | H5 / H6 | prefetch + 4-byte pre-compare |
| 10 (static), 11 | H10 + Zopfli | H10 + Zopfli | none (`hash_to_binary_tree_inc.h` no diff; `backward_references_hq.c` renames + DCHECK) |

The size_hint branch is attacker-influenced (it follows the first IIS input chunk size); both
branches were reviewed.

### New code: H58 / H68 (q5-7) - no out-of-bounds or uninitialized-influence found

- **Table indexing.** `hash_shift_ = 32 - bucket_bits - 8` (`hash_longest_match_simd_inc.h:51`), so
  `key = hash >> 8` has exactly `bucket_bits` bits; offsets `minor_ix + (key << block_bits)`
  (`:102-103`) stay within `bucket_size * block_size` (`:87-89`). H68 hashes 5 bytes into 23 bits
  with `bucket_bits` fixed at 15 (`hash_longest_match64_simd_inc.h:31`, `:68-69`;
  `quality.h:173` sets 15).
- **Tag scan bounds.** `block_bits = quality - 1` = 4..6, so `chunk_count = block_size/16` = 1..4;
  the SSE2 loop reads `tag_bucket + 16*i` for `i < chunk_count && i < 4` (`matching_tag_mask.h:23-25`),
  inside the bucket's own row. Safety relies on `BROTLI_MAX_SIMD_QUALITY <= 7`; nothing in the build
  raises it.
- **Uninitialized tags/buckets.** `Prepare` sets only `num[]` to 65535 (`:65-78`); `tags_` and
  `buckets_` are never cleared. `n = 65535 - num[key]` counts stored entries and
  `mask = (block_has_unused_slots << (n & 63)) - 1` (`:227-230`) keeps exactly the `n` newest slots
  after the rotate-by-`head` (`matching_tag_mask.h:62-64`), so no unwritten slot reaches
  `bucket[rb_index]`. Shift amount is <= 63 (n < block_size <= 64 in that branch). Even a leaked slot
  would only yield a `prev_ix` that is bounds-checked (`:240-246`) and byte-verified against real
  ring-buffer data, so it could not inject heap bytes into the stream. See P1.
- **Match-length reads.** The 4-byte pre-compare reads `[best_len-3, best_len]` with `best_len >= 3`
  forced (`:218-220`) and guarded by `cur_ix_masked + best_len <= mask` and
  `prev_ix + best_len <= mask` (`:240-246`). H68's `max_length - 4` (`hash_longest_match64_simd_inc.h:249`)
  cannot underflow: callers guarantee `position + HashTypeLength(8) < pos_end`
  (`backward_references_inc.h:38`, `:70`, `:106`), so `max_length >= 8`. Reads past `mask` land in
  the ring-buffer tail and 7-byte slack exactly as H5/H6 did in 1.1.0.
- **TZCNT input.** `BROTLI_TZCNT64(matches)` runs only inside `for (; matches > 0; ...)` (`:231-233`).
- **Bucket counter wrap.** `num[key]` is `uint16_t`; after 65,536 stores to one bucket, `n` restarts at
  0 and that bucket's history is masked for up to one block. Compression-ratio blip only; H5's
  count-up counter in 1.1.0 has the same blip.

### Changed shared code - safe

- **H5/H6/H40-42 4-byte pre-compare** (`hash_longest_match_inc.h`, `hash_longest_match64_inc.h`,
  `hash_forgetful_chain_inc.h` diffs): `best_len` is raised to 3 before the bucket loop and every read
  stays at `<= cur_ix_masked + best_len <= mask`. It is a strictly necessary condition for a longer
  match, so match results are unchanged. The `continue -> break` for `cur_ix_masked + best_len > mask` is
  equivalent because `cur_ix` is fixed and `best_len` only grows. The new `PREFETCH_L1` calls
  (`platform.h:617-621`, `_mm_prefetch`) target in-allocation addresses and cannot fault.
- **Entropy refactor.** `EstimateEntropy` (`encode.c:245-256`) is algebraically equal to the removed
  `ShannonEntropy`; `FastLog2(0)` = `kBrotliLog2Table[0]` = 0, and the table is const.
  `literal_cost.c` / `block_splitter_inc.h` / `ShouldCompress` (`encode.c:452-455`) are algebraic
  rewrites. Floating-point rounding may differ, so output bytes may differ from 1.1.0 for the same
  input. Streams stay valid.
- **Static tables.** In 1.2.1 the dictionary hash, LUT and dictionary data moved into `*_inc.h` and stay
  `const` under the default `BROTLI_STATIC_INIT_NONE` (`static_dict_lut.h` `#else` branch,
  `dictionary_hash_inc.h:1`, `static_dict_lut_inc.h:1`, `:1277`). Content was compared by parsing both
  tags. `kBrotliDictionaryData` (122,784 bytes), `kStaticDictionaryHashWords/Lengths` and
  `kStaticDictionaryBuckets` are identical. `kStaticDictionaryWords` has identical entry sets and
  end-of-bucket markers in all 32,768 buckets, but a different order in 842 buckets. This is used
  only by `BrotliFindAllStaticDictionaryMatches` (q10/11), whose `AddMatch` keeps the minimum
  (`static_dict.c:20-24`), so no output effect is expected (**UNVERIFIED** by execution). `Hash15`
  (`hash_base.h`) equals the removed `Hash` (same multiplier and shift; v1.1.0
  `static_dict_lut.h:26-27`).
- **Integer widening.** The `(size_t)1u << bits` fixes (`hash.h` compound paths,
  `compound_dictionary.c`, `EstimatePeakMemoryUsage`) are on paths the plugin never calls.
- **Allocation.** Hasher sizes are fixed per quality (`HashMemAllocInBytes`, allocated once in
  `HasherSetup`, `hash.h:438-452`). The ring buffer is bounded by lgwin/lgblock. `size_hint` is capped
  at 1<<30 and only selects a hasher. No attacker-sized allocation exists in either version.
- **Public API** (`encode.h`, `types.h`, `port.h`): doc and IWYU comments only. The removed
  `BROTLI_INTERNAL` override hook is irrelevant here.

## 2. Static initialisation in a multi-threaded DLL - safe

`common/static_init.h:34-38`: `BROTLI_STATIC_INIT_DEFAULT` is `NONE`, and no build input defines
`BROTLI_STATIC_INIT`. In NONE mode all encoder tables are compile-time `const` data in `.rdata`.
`BrotliEncoderEnsureStaticInit` returns `BROTLI_TRUE` unconditionally (`enc/static_init.c:47-49`),
and `BrotliEncoderCreateInstance` (`encode.c:763`) does no lazy work. Concurrent `CreateCompression`
calls share only read-only data, and each encoder's state is per-instance (`BrotliBootstrapAlloc` ->
CRT `malloc`). There is no `DllMain`, TLS or loader-lock dependency. The other modes cannot be
selected by accident on this toolchain: EARLY needs `__attribute__((constructor))`
(`enc/static_init.c:37`), which MSVC C rejects at compile time. LAZY compiles, but nothing in the C
library calls `BrotliEncoderLazyStaticInit` (only `static_init_lazy.cc`, which is not built
defines it), so every `CreateInstance` would return NULL. That fails closed as `E_FAIL`; it would
not corrupt memory.

## 3. Upstream commits not in v1.2.1 that touch c/enc, c/common, c/include

All commits are on `master` after `v1.2.0`. None fixes a defect that is reachable under the plugin's
call pattern.

| commit | what | reachable for plugin? | in 1.1.0? |
|---|---|---|---|
| `e230f47` | `BROTLI_MODEL` off for IA64/LoongArch | no (macro empty on MSVC) | n/a |
| `486ed5b` | DCHECK off-by-one (`<= mask + 1`) | no: `BROTLI_DCHECK` is compiled out without `BROTLI_DEBUG`/`BROTLI_ENABLE_LOG` (`platform.h:464-468`) | n/a |
| `54f74c7` | quick hasher (H2-H4/H54) adds `cached_backward <= max_backward` and enables compound dict for q3/4 | no: without a compound dictionary and with `stream_offset = 0`, `dist_cache[0]` only stores distances `<= min(position, max_backward_limit)` (`backward_references_inc.h` dist-cache update), so the check is redundant | same code, same reasoning |
| `2c137d8`, `7c2def1` | C89 declaration placement | no (MSVC accepts) | n/a |
| `4792c8e` | compound-dict total-size overflow (decoder) + moves platform.h brace (see P4) | no: decoder not linked | n/a |
| `1736fe1` | RAW dictionary size caps in `CreatePreparedDictionary` / `AttachPreparedDictionary` | no: plugin attaches no dictionary | yes (unchecked there too; unreachable) |
| `037b70e`, `0d1f629`, `aa62fac`, `f297c64`, `30cd40b`, `7b93874` | Base64 mode feature and its fixes | no: feature absent from 1.2.1 | no |
| `8e10eeb` | `BROTLI_PARAM_SIMD_HASHER`; non-MSVC default lowered to q<=6 | no defect; MSVC x64 default unchanged at q<=7 | n/a |
| `09e1ac6`, `85c2aaf`, `1b34d3b`, `447439d`, `11017d7`, `e45eb45`, `8e6c366`, `cf1742a`, `558fc64`, `42a2ed4`, `392b261`, `86ee1f6` | experimental "opt" hasher H59 + compound-dict prefetch; `392b261` is an OOB-read fix inside `backward_references_opt_inc.h` | no: that file does not exist at `v1.2.1` (`git cat-file` fails) | no |
| `a3abcbe` | mirror first-write bytes into the ring-buffer tail | no as far as the source shows (P5) | yes (`ringbuffer.h` logic is identical) |
| `bb819ba`, `0ed4268` | typo; decoder | no | n/a |

## 4. Behavioural compatibility of the plugin's call pattern - unchanged

`UpdateSizeHint` through `BrotliEncoderIsFinished`/`TakeOutput`, `EncodeData` and
`InjectFlushOrPushOutput` are textually identical between `v1.1.0` and `v1.2.1` (function-range
diffs empty). `BrotliEncoderSetParameter` still returns FALSE once `is_initialized_` is set
(`encode.c:63`), which the plugin ignores as intended.

- **Hang / endless S_OK.** No new route. `PROCESS` with input always either copies to the ring buffer
  or drains output. `FINISH` with `available_out > 0` always makes progress until
  `stream_state_ == FINISHED` and no output is pending (`encode.c:1609-1697`, `:1699`). The pattern
  would spin only if IIS passed an empty output buffer with empty input. That is identical in 1.1.0,
  and IIS doing it is **UNVERIFIED**.
- **Truncation / invalid stream.** `CompressStream` returns FALSE only on OOM or API misuse
  (`:1613`, `:1617-1633`, `:1687`). Output that does not fit is held in `available_out_` and drained
  on later calls. No size- or quality-dependent failure mode exists (see P2).

## 5. Performance

- **q4 (dynamic).** H4/H54 code is unchanged; metablock and entropy code differs only in algebraic FP
  rewrites. Expect parity (**UNVERIFIED**: no benchmark run).
- **q10 (static).** H10/Zopfli are unchanged. The static-dictionary LUT order change does not change
  work done. Expect parity (**UNVERIFIED**).
- **q8-9.** H5/H6 gain bucket prefetch and the 4-byte pre-compare. Expect a modest speedup
  (**UNVERIFIED**).
- **q5-7.** New SIMD-tag matchers. Upstream's own comment says they are faster up to q7 on `_M_X64`
  (`platform.h:647-649`; `8e10eeb` keeps 7 as the MSVC recommendation). Memory cost is in O1.
- **/arch:AVX2 vs none.** No AVX/AVX2/BMI-gated source exists in either version
  (`git grep __AVX|_mm256|__BMI` finds nothing). The only intrinsics are SSE2 (x64 baseline,
  `matching_tag_mask.h:6-8`), `_mm_prefetch` and `_tzcnt_u64`. `/arch:AVX2` changes only VEX encoding
  and auto-vectorisation, so the expected difference remains small and unmeasured. The 1.1.0-era
  CLAUDE.md caveat still applies unchanged.
- **BMI1 / TZCNT.** The dependency is not new: 1.1.0 already used `_tzcnt_u64` in
  `FindMatchLengthWithLimit` (v1.1.0 `platform.h:479`, `find_match_length.h:31`). 1.2.1 adds two call
  sites (`hash_longest_match_simd_inc.h:233`, `hash_longest_match64_simd_inc.h:260`). Every call site
  passes a non-zero value (`find_match_length.h:28` `if (x != 0)`; the SIMD loops run
  `while matches > 0`). On a CPU without BMI1, the TZCNT encoding (`F3 0F BC`) executes as BSF, which
  gives the same result for non-zero input, so behaviour is identical. A zero input (TZCNT -> 64,
  BSF -> destination undefined) is unreachable. **UNVERIFIED** (no disassembly): that MSVC emits TZCNT
  for `_tzcnt_u64` with no `/arch` flag. Every AVX2-capable x86 CPU also has BMI1, so the AVX2 variant
  is unaffected either way.

## Findings

**O1 - Operational (conditional). Qualities 5-7 now run new matcher code with a larger
per-encoder footprint.**
- What changes: q5-7 select H58/H68 instead of H5/H6 (`quality.h:168`, `:180`), and the matchers
  allocate an extra `bucket_size * block_size` byte tag array (`hash_longest_match_simd_inc.h:88`).
- Extra memory per concurrent compressed response: +256 KiB (q5, H58), +512 KiB (q6), +2 MiB (q7),
  and +0.5/1/2 MiB with H68. At q7 that is about +25% of hasher memory, roughly +12% of the encoder
  total (8 MiB ring buffer at lgwin 22).
- Reachable: yes, but only if either level is set to 5-7. The runbook's own fallback ("lower to 9
  then 7", "lower this to 7-8": `CLAUDE.md:59`, `:61`) lands exactly on this code, which is the least
  exercised in this deployment. No defect was found in it (section 1).
- Present in 1.1.0: no.
- Action: before using 5-7 as an emergency fallback, benchmark it and check peak memory; prefer 8-9
  as the fallback.

**P1 - Polish. New reads of uninitialized heap bytes in the SIMD tag scan, masked before use.**
- `tags_` is never cleared, yet whole 16-byte rows are loaded (`matching_tag_mask.h:23-25`); the
  result is masked to written slots (`hash_longest_match_simd_inc.h:227-230`).
- Reachable: yes at q5-7. It cannot influence output bytes (section 1), but MSan-style tooling would
  flag it.
- Present in 1.1.0: no.

**P2 - Polish (doc). The runbook's truncation explanation does not match the code.**
- `CLAUDE.md:61` says `CompressStream` returns FALSE when the encoder buffers more than IIS's output
  buffer can drain, and recommends lowering the level.
- The encoder holds pending output internally and returns FALSE only on OOM or misuse
  (`encode.c:1613-1687`), so lowering the level has no mechanism to fix truncation. Under the default
  `BROTLI_ENCODER_EXIT_ON_OOM`, a mid-stream allocation failure exits the process rather than returning
  `E_FAIL`; only the up-front `CreateCompression` allocation (`BrotliBootstrapAlloc`, plain `malloc`)
  fails soft. *(Corrected 2026-10-28 per the gate-1 codex review [O1]: the original text said a
  mid-stream `E_FAIL` points at allocation failure.)*
- Reachable: n/a (documentation). Present in 1.1.0: yes (same code).

**P3 - Polish. The DLL version resource still says 1.1.0.**
- `src/CMakeLists.txt:3-6` hard-codes 1.1.0.0, and `brotli.rc.in:6-7`, `:22-23` stamp it into
  FILEVERSION/ProductVersion. The 1.2.1 build would therefore report 1.1.0 in Explorer and inventory
  tools.
- Reachable: every 1.2.1 build. Present in 1.1.0: no. A fix touches `src/` (no-local-changes policy).

**P4 - Polish. Macros and an include sit inside a function body in 1.2.1 `platform.h`.**
- `PREFETCH_*`, `BROTLI_MAX_SIMD_QUALITY` and `#include <mmintrin.h>` lie inside the body of
  `BrotliSuppressUnusedFunctions` (`platform.h:580-653`).
- It is benign on MSVC: macros are file-scoped, and `<intrin.h>` (`:35`) has already pulled
  `mmintrin.h`, so the include is a guarded no-op. Upstream moved the brace in `4792c8e`.
- Reachable: compile-time only. Present in 1.1.0: no.

**P5 - Polish (residual). After the first-write shortcut, part of the ring-buffer tail is left
uninitialized.**
- `ringbuffer.h:105-117` and `:128` initialise only `tail[0]`; `tail[1..n)` keeps stale heap bytes.
- Upstream `a3abcbe` (master only) now mirrors these bytes, because its new opt hasher dropped the
  bounds checks.
- 1.2.1 keeps the `cur/prev + best_len <= mask` checks in every matcher. Lap-0 comparisons never run
  past written data, and wrap-crossing writes (`:135-145`) rewrite the tail before any later lap can
  compare into it. So the stale bytes are not reached as far as the source shows (**UNVERIFIED** by
  execution).
- Literals are always read through `& mask`, so even a stale-byte comparison could cause at most a
  mis-encoded match (bad decode), never a heap-byte leak.
- Present in 1.1.0: yes (`ringbuffer.h` logic identical).

## Residual risks

1. Nothing here has been measured. Qualities 4, 10 and the 5-7 fallback, with and without AVX2,
   need an A/B benchmark plus a round-trip decode check on representative bodies before deploy.
2. The H58/H68 safety argument rests on `block_bits <= 6`, i.e. `BROTLI_MAX_SIMD_QUALITY <= 7`. Never
   pass `BROTLI_MAX_SIMD_QUALITY` or `BROTLI_STATIC_INIT` defines into this build.
3. Hosts that hide BMI1 from the guest (Hyper-V compatibility mode) still execute TZCNT natively as
   TZCNT or BSF, with identical results for the non-zero inputs used. AVX2 masking remains the real
   crash risk for the AVX2 variant, as the CLAUDE.md caveat says.
4. No CVE/advisory database was consulted (source deltas only).
