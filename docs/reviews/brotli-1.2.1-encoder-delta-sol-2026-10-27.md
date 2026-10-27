**Verdict: qualified yes for the stated release/default configuration.** This static audit found no new reachable memory-corruption or response-data disclosure defect in v1.2.1 relative to v1.1.0. Operational parity is qualified: qualities 5–7 allocate additional hash-table memory, default OOM handling can terminate the worker process in both versions, and v1.2.1 introduces an assertion failure in builds with Brotli debug assertions enabled.

**Scope and evidence**

Verified locally:

| Reference | Commit |
|---|---|
| v1.1.0 | `ed738e842d2fbdf2d6459e39267a633c4a9b2f5d` |
| v1.2.1 | `db24a98aed38a16de78cc05ca15cdd8dc2a0d92d` |
| Local `origin/master` | `089e71983611a42643d75194fedfde086c5e58af`, dated 2026-10-27 |

References below use `revision:path:line`. The audit examined the encoder/common/header diff, new SIMD hashers, initialization, ring-buffer and streaming paths, and locally recorded master changes omitted from v1.2.1.

No network, builds, tests, clone modifications, or process inspection/cleanup were performed. The clone remained clean. The IIS integration and build configuration are taken from the supplied description; the actual plugin source, effective compiler definitions, generated instructions, and deployed DLL are **UNVERIFIED**.

### [O1] Operational — allocation failure can terminate `w3wp.exe`

**Reachable: yes, if an internal allocation fails and the build uses Brotli’s default OOM policy. Present in v1.1.0: yes.**

Unless `BROTLI_ENCODER_CLEANUP_ON_OOM` or an explicit exit policy is defined, the library selects `BROTLI_ENCODER_EXIT_ON_OOM`. Its allocator calls `exit(EXIT_FAILURE)` when allocation fails:

- v1.2.1: `c/enc/memory.h:18-21`, `c/enc/memory.c:46-51`.
- v1.1.0: `c/enc/memory.h:22-25`, `c/enc/memory.c:51-56`.

For a library inside an IIS worker, that is a process-level availability risk. Attacker-influenced response size and concurrency can increase allocation pressure; this is not evidence that any particular request can reliably exhaust this host.

Quality 10 already has substantial per-response storage. Its full H10 forest is `2 * sizeof(uint32_t) * (1 << 22)` = **32 MiB**, plus **0.5 MiB** of hash buckets. The full ring is another **8.25 MiB**, before commands, cost models, output storage, and histogram workspaces. These formulas are unchanged from v1.1.0:

- Both versions: `c/enc/hash_to_binary_tree_inc.h:81-89`.
- v1.2.1: `c/enc/hash.h:227-230`, `c/enc/quality.h:75-107`, `c/enc/ringbuffer.h:54-61`.
- Quality-10 temporary allocations: `c/enc/backward_references_hq.c:106-107,802-804`.

The effective OOM definition in the plugin build is **UNVERIFIED**. Static CRT linkage does not change the library’s explicit choice to call `exit()`.

### [O2] Operational — qualities 5–7 have new, bounded memory overhead

**Reachable: yes, at fallback qualities 5–7 on MSVC x64. Present in v1.1.0: no.**

H58/H68 add one tag byte per bucket slot while retaining the position arrays and counters:

- H58: `v1.2.1:c/enc/hash_longest_match_simd_inc.h:80-89`.
- H68: `v1.2.1:c/enc/hash_longest_match64_simd_inc.h:100-109`.
- Old allocation formulas: `v1.1.0:c/enc/hash_longest_match_inc.h:91-99`, `hash_longest_match64_inc.h:92-100`.

Additional tag storage per response, calculated from `quality.h:172-185`:

| Quality | H58 branch | H68 branch |
|---|---:|---:|
| 5 | 0.25 MiB | 0.5 MiB |
| 6 | 0.5 MiB | 1 MiB |
| 7 | 2 MiB | 2 MiB |

This is an allocation increase, not an unbounded-allocation defect. It can increase concurrency pressure and the exposure described in O1. Qualities **4 and 10 do not select these new hashers**.

Throughput gains or regressions on the IIS workload are **UNVERIFIED**; the source establishes the changed mechanism and memory cost, not benchmark results.

### [O3] Operational, conditional — new assertions reject a valid ring-boundary case

**Reachable through the call pattern: yes, with active Brotli assertions. Reachable in an ordinary build without debug/log definitions: no. Present in v1.1.0: no.**

New checks require:

```c
cur_ix_masked + max_length <= ring_buffer_mask
```

A block may validly end at `ring_buffer_mask + 1`. With the default window, an input block ending at the **8 MiB main-ring boundary** can violate the assertion.

Examples:

- Quality 4: `v1.2.1:c/enc/hash_longest_match_quickly_inc.h:167`.
- H58: `c/enc/hash_longest_match_simd_inc.h:173`.
- H68: `c/enc/hash_longest_match64_simd_inc.h:198`.
- Quality 10: `c/enc/backward_references_hq.c:436`.

Upstream commit **`486ed5b`** changes these bounds to `ring_buffer_mask + 1`; it is omitted from v1.2.1.

`BROTLI_DCHECK` expands to `assert` only with `BROTLI_DEBUG` or `BROTLI_ENABLE_LOG`; otherwise it disappears (`v1.2.1:c/common/platform.h:464-470`). Assertion termination also requires assertions not to have been disabled by `NDEBUG`. Thus this is a conditional build regression, not a release-path memory-corruption finding.

**Hasher selection under the actual parameters**

An important qualification: **not setting a size hint does not mean the encoder always uses zero**. `UpdateSizeHint` derives one from accumulated input plus remaining input at the first encode, capped at 1 GiB (`v1.2.1:c/enc/encode.c:1594-1606,1684`). Hasher selection then occurs once during setup (`c/enc/hash.h:439-476`).

Consequently, a sufficiently large initial input submission can select the “large input” branch. A large response delivered in small chunks can retain the smaller initial hint.

| Quality | v1.1.0 | v1.2.1, MSVC x64 | Internal input block |
|---|---|---|---:|
| 4 | H4; H54 if hint ≥1 MiB | Same | 64 KiB |
| 5 | H5; H6 for large hint | **H58; H68 for large hint** | 64 KiB |
| 6 | H5; H6 for large hint | **H58; H68 for large hint** | 64 KiB |
| 7 | H5; H6 for large hint | **H58; H68 for large hint** | 64 KiB |
| 8 | H5; H6 for large hint | Same families | 64 KiB |
| 9 | H5; H6 for large hint | Same families | 256 KiB |
| 10 | H10 binary tree/Zopfli | Same | 256 KiB |

Evidence: `v1.1.0:c/enc/quality.h:157-180`; `v1.2.1:c/enc/quality.h:75-107,156-187`.

MSVC x64 defines `BROTLI_TZCNT64`, and `_M_X64` therefore makes `BROTLI_MAX_SIMD_QUALITY` **7**, independently of `/arch:AVX2` (`c/common/platform.h:531-540,647-652`). The small-window and large-window substitutions are unreachable with the default `lgwin=22`.

**Memory-safety assessment**

**SIMD/tag hashers.** No reachable out-of-bounds access or output disclosure was identified in the new H58/H68 paths.

- At qualities 5–7, bucket sizes are 16, 32, or 64 slots. `GetMatchingTagMask` reads corresponding 16-byte chunks, at most four, within the allocated tag bucket. The loads explicitly permit unaligned addresses (`c/enc/matching_tag_mask.h:16-28`).
- Counts initialize to 65535; stores decrement them and write both the position and tag. After rotating the comparison mask, the code masks off unused slots **before** reading candidate positions (`hash_longest_match_simd_inc.h:62-77,95-107,221-234`; `hash_longest_match64_simd_inc.h:81-96,115-128,246-261`).
- Thus allocated but unwritten tag bytes are read by the vector load, but their comparison bits are discarded. I found no surviving dependency from those bytes to candidate selection or response bytes.
- The unsigned 16-bit counter can wrap after repeated stores. It can temporarily reduce the candidates considered; the masked indices remain bounded. The older H5/H6 also use wrapping 16-bit counters. This does not establish a new memory-safety defect.
- The new four-byte rejection probes first raise `best_len` to at least three and check the endpoints before loading four bytes ending at that position (`hash_longest_match_simd_inc.h:218-246`; `hash_longest_match64_simd_inc.h:243-274`). The corresponding H5/H6 changes retain those guards.
- H68’s `max_length - 4` does not underflow through this caller. Its normal search requires more than eight bytes remaining; the lazy-search bounds preserve sufficient input (`backward_references_inc.h:38,70-107`; `hash_longest_match64_simd_inc.h:23-24,249,280-282`).

The hash multiplications use unsigned types, so their wraparound is intentional. `hash_base.h` preserves the old multiplier and Hash14 computation and supplies the equivalent Hash15 operation (`v1.2.1:c/enc/hash_base.h:14-36`; v1.1.0 counterparts in `hash.h:74-91` and `static_dict_lut.h:26-27`).

**Static initialization and concurrency.** The default is safe from the proposed new first-use initialization race.

`BROTLI_STATIC_INIT_DEFAULT` is **`BROTLI_STATIC_INIT_NONE`**, meaning compile-time data, not lazy runtime initialization (`c/common/static_init.h:27-38`). In this mode:

- `BrotliEncoderEnsureStaticInit()` simply returns true (`c/enc/static_init.c:47-54`).
- Dictionary hash and lookup arrays are declared `const` (`c/enc/dictionary_hash.h:34-38`, `static_dict_lut.h:38-42`).
- Their generated initializers are included directly (`dictionary_hash.c:136-140`, `static_dict_lut.c:214-218`).
- Each create allocates and initializes its own encoder state (`encode.c:761-776`).

There is no new shared table construction during concurrent `CreateCompression` calls under this default.

The alternate modes require separate integration scrutiny. In particular, the lazy branch of `EnsureStaticInit` only returns `kLazyInitOk`; it does **not** invoke `BrotliEncoderLazyStaticInit()`. The supplied C++ helper performs once-only initialization when explicitly called (`static_init.c:40-54`, `static_init_lazy.cc:8-24`). That distinction is unreachable when no static-init definition is supplied.

I also compared the moved generated data through read-only shell processing:

- All **122,784 dictionary bytes** match v1.1.0.
- Dictionary-hash words, lengths, and lookup-bucket offsets match.
- The **31,705 lookup entries** are reordered in places, but the comparison found identical entry multisets in all **9,584 nonempty buckets**.

Sources: `v1.1.0:c/common/dictionary.c:15`, `dictionary_hash.c:17,1001`, `static_dict_lut.h:29,1304`; corresponding v1.2.1 initializers in `dictionary_inc.h:1`, `dictionary_hash_inc.h:2,987`, `static_dict_lut_inc.h:2,1278`. Reordering can affect match selection; byte-identical compressed output is not established.

**Ring buffer and bytes past `size_`.** These bytes must be separated into the allocated mirror tail and the seven-byte hashing slack.

- The full allocation contains the main ring, a tail of one input-block size, two preceding bytes, and seven final slack bytes. Allocation and copying account for those regions (`v1.2.1:c/enc/ringbuffer.h:54-88`).
- A short first write allocates only its length plus slack. Promotion to the full ring does **not** initialize the entire tail: it initializes the two final main-ring bytes and sets `buffer_[size_] = 241` (`ringbuffer.h:104-128`).
- Subsequent writes mirror the appropriate head bytes into the tail (`ringbuffer.h:91-100,130-146`).
- During the first lap, `CopyInputToRingBuffer` clears seven bytes beyond newly supplied input (`encode.c:818-870`).
- Reads past the main-ring boundary can therefore be within the allocation; “past `size_`” alone is not an out-of-bounds finding.

Upstream **`a3abcbe`** replaces the single-byte tail initialization with copying the short first-write prefix into its mirror (`origin/master:c/enc/ringbuffer.h:126-130`). That missing prefix mirror is also present in v1.1.0 (`c/enc/ringbuffer.h:108-148`); the ring-buffer algorithm itself did not change between the audited tags.

For this PROCESS/FINISH-only pattern, internal blocks remain aligned until the final block. Before wrapping, comparison limits keep the current input within supplied data; after wrapping, the newly written head supplies the tail bytes needed for crossing history comparisons. The H10 stitching loop also limits its work to the available new prefix (`hash_to_binary_tree_inc.h:299-323`). I did **not** establish a reachable output-dependent uninitialized tail read in this pattern. A general proof covering other operations or parameter combinations is **UNVERIFIED**.

**Integer overflow and allocation growth.** No newly introduced overflow or allocation growing indefinitely with response length was identified under these fixed parameters.

Input copying is capped by the internal block size (`encode.c:45-57,1640-1655`). The ring and hash tables have fixed parameter-derived bounds. Metablock accumulation is capped before another block is merged, and command/output allocation sizes derive from those bounded blocks (`encode.c:1061-1076,1118-1142,1161-1166`). This does not impose a response CPU budget or an aggregate concurrency limit.

The changed null-pointer arithmetic in block clustering is a hardening improvement on an allocation-failure path, not a new defect (`v1.2.1:c/enc/block_splitter_inc.h:230-246`; v1.1.0 counterpart `:228-242`).

**Streaming and behavioral compatibility**

No changed PROCESS/FINISH or `IsFinished` semantics were found.

| Concern | Assessment and evidence |
|---|---|
| Repeated `SetParameter(QUALITY)` | Both versions reject **all** parameter changes once initialized, even setting the same value. The first accepted quality remains effective. `v1.2.1:encode.c:60-72`; v1.1.0 `:62-74`. |
| When initialization occurs | The first `CompressStream` calls `EnsureInitialized`; it sets `is_initialized_` before returning. `v1.2.1:encode.c:624-677,1613`. |
| Late runbook quality reduction | It affects newly created response contexts. It cannot change a context already initialized. Ignoring the parameter return does not corrupt state; it conceals a rejected change. |
| PROCESS consumes input but emits nothing | Expected: input blocks and metablocks may be buffered. `encode.c:1118-1142,1647-1655`. |
| Empty-input FINISH drain | Supported. FINISH encodes remaining buffered input, marks the stream finished, and drains internal output across calls. `encode.c:1658-1696`. |
| `IsFinished` | Requires both finished state **and no pending internal output**. `encode.c:1699-1706`; v1.1.0 `:1675-1682`. |
| Empty response | An empty finalized stream is explicitly emitted. `encode.c:980-990`. |
| Nullable `total_out` | Explicitly supported. `encode.c:1360-1370`; public contract `c/include/brotli/encode.h:425-428`. |

With successful library calls, correct buffer accounting, and eventual output capacity, the described drain loop has no identified new hang, truncation, or invalid-stream path. FINISH repetition is also the documented contract (`c/include/brotli/encode.h:93-109,405-415`).

Two inherited integration conditions remain:

- Repeated calls with no output capacity cannot drain pending output; `IsFinished` correctly remains false (`encode.c:1387-1399,1699-1706`). IIS’s actual buffer-provision behavior is **UNVERIFIED**.
- `CompressStream` can return false. Error propagation by the actual plugin is **UNVERIFIED**; the supplied description explicitly identifies ignored parameter returns but does not establish its handling of compression failures. An unconditional S_OK retry after failure would be an integration risk, not a demonstrated v1.2.1 regression.

**Upstream changes omitted from v1.2.1**

The local history requires a release-branch distinction:

- v1.2.0 is dated **2025-10-27**.
- v1.2.1 is dated **2026-10-21**.
- Between those tags, `c/enc` has **no changes**; the relevant common change is version metadata. The substantive v1.2.1 backport is decoder commit **`b418fa8`**, equivalent to master’s **`0ed4268`**.
- No encoder/common/header commit later than the v1.2.1 release commit was found in this local master snapshot. The newest relevant master commit, `bb819ba`, predates the release commit on the same day.

This was checked with range logs, the tag diff, and a patch-equivalence log. A commit appearing in `v1.2.1..origin/master` is not necessarily post-release by date or an omitted fix: `0ed4268` is the important cherry-pick example.

The following accounts for the omitted non-merge changes. “Baseline” refers to the underlying defect when there is one; performance/features have no defect to compare.

| Commit | Change and evidence | Reachable issue here? | Baseline v1.1.0 |
|---|---|---|---|
| `e230f47` | Disable model attributes for additional targets. MSVC already gets an empty `BROTLI_MODEL` (`v1.2.1:platform.h:668-672`). | **No**; portability/Polish for this build. | New attribute machinery absent. |
| `486ed5b` | Correct boundary assertions; see O3. | **No** in ordinary release; **yes** with active assertions. | **No**; regression. |
| `54f74c7` | Enable prepared dictionaries for q3/q4; also adds a cached-distance limit check (`git show`, `hash_longest_match_quickly_inc.h` hunk at 168). | **No demonstrated defect** here: no prepared dictionaries; ordinary cached distances remain window-bounded. | Existing omission, but no reachable failure established here. |
| `2c137d8` | Move loop variable declaration for older C compilers (`v1.2.1:encode.c:245-252`). | **No** runtime issue; compiler portability. | Exact new loop absent. |
| `7c2def1` | Move declarations for ISO-C compilation, including `CreateInstance` (`v1.2.1:encode.c:761-770`). | **No** runtime fix; MSVC build acceptance remains untested. | Exact new mixed declaration absent. |
| `4792c8e` | Checked addition for **decoder** compound dictionaries (`git show`, `c/dec/decode.c` hunk at 1526). | **No**; decoder unlinked. | **Yes**, unchecked decoder accumulation exists at `v1.1.0:c/dec/decode.c:1484`. |
| `1736fe1` | Add encoder RAW-dictionary source/aggregate size limits (`git show`, `compound_dictionary.c` hunks at 155 and 183). | **No**; no dictionary preparation/attachment. | **Yes**, missing checks also exist in `v1.1.0:compound_dictionary.c:153-189`; not an upgrade regression. |
| `037b70e` | Introduce optional Base64 processing. | **No**; feature absent from both release tags. | **No**. |
| `0d1f629` | Fix Base64 histogram bounds, context-map construction, and region mapping (`origin/master:block_encoder_inc.h:21`, `metablock.c:152,415,784`). | **No**; affected machinery absent from v1.2.1. | **No**. |
| `8e10eeb` | Add explicit SIMD-hasher selection parameter. Existing v1.2.1 selection is automatic (`quality.h:166-186`). | No defect fixed; useful control absent from release. | New SIMD hashers absent. |
| `aa62fac` | Restore wrapped positions after the Base64 feature changed them. | **No**; v1.2.1 already uses `wrapped_last_flush_pos` in `encode.c:511-594`, as does v1.1.0. | **No** regression in either release. |
| `09e1ac6` | Introduce opt-in H59. Master initializes `hasher_opt=false` (`origin/master:encode.c:722`, `quality.h:200`). | **No**; absent from v1.2.1. | **No**. |
| `f297c64` | Base64 minimum region length, duplicate handling, and skipped-trigger checks. | **No**; Base64 machinery absent. | **No**. |
| `30cd40b` | Portable Base64 trigger constant representation (`git show`, `backward_references.c` hunk at 52). | **No**; portability/Polish in absent feature. | **No**. |
| `447439d` | Hoist prepared-dictionary calculations into optimized lookup. | **No**; optimized path absent and no prepared dictionary. | **No** corresponding new path. |
| `85c2aaf` | Give H59 its own implementation copy (`git show`, `hash.h` hunk at 292). | **No**; H59 absent. | **No**. |
| `a3abcbe` | Mirror the initial short-write prefix into the tail; discussed above. | Setup state is reachable; **no bad read established for this pattern**. Output/security consequence remains **UNVERIFIED**. | **Yes**, same missing mirror; not a ring-buffer regression. |
| `1b34d3b` | Outline H59 `StoreRange` (`git show`, optimized hasher hunk at 105). | **No**; H59 absent. | **No** corresponding path. |
| `11017d7` | Prefetch prepared-dictionary contents in optimized path. | **No**; path absent, no prepared dictionary. | **No** corresponding path. |
| `8e6c366` | Reuse optimized prepared-dictionary probe calculations. | **No**; same exclusion. | **No** corresponding path. |
| `e45eb45` | Add optimized dictionary-head prefetching. | **No**; same exclusion. | **No** corresponding path. |
| `cf1742a` | Two-byte last-distance precheck in H59. | **No**; H59 absent. | **No** corresponding path. |
| `558fc64` | Improve lazy-search lower bound in H59. | **No**; H59 absent. | **No** corresponding path. |
| `42a2ed4` | Remove boundary guards in optimized H59/dictionary paths. | **No**; those paths absent. This is not a release safety fix. | **No** corresponding path. |
| `392b261` | Bound the position used by new dictionary-head prefetching (`392b261:c/enc/backward_references_opt_inc.h:213-221`). | **No**; faulty optimized prefetch does not exist in v1.2.1, and no prepared dictionary is supplied. | **No**; master-only regression. |
| `86ee1f6` | Replace that bound check by prefetching at bounded `range_end` (`origin/master:backward_references_opt_inc.h:213-218`). | **No**; same exclusion. | **No**. |
| `7b93874` | Fix Base64 processing when a backward reference covers its trigger (`origin/master:backward_references_inc.h:41-61`). | **No**; Base64 feature absent. | **No**. |
| `bb819ba` | Documentation macro spelling correction in `types.h`. | **No**; Polish only. | Documentation typo exists; no encoder defect. |

`b1e421f` is a merge record, not an additional independent fix. `0ed4268`/`b418fa8` concerns decoder block-switch validation, so its security benefit does not apply to this encoder-only DLL. The older decoder behavior is visible at `v1.1.0:c/dec/decode.c:1127-1139`.

**Performance and CPU instructions**

For **quality 4**, H4/H54 remain the selected families. Their matching algorithm is essentially unchanged apart from the new assertion and supporting refactors (`hash_longest_match_quickly_inc.h` diff). Shared entropy changes still apply.

For **quality 10**, H10 and the Zopfli path remain selected (`encode.c:1094-1101`). Relevant changes include floating-point cost-expression rearrangements in `literal_cost.c:105-122` and `block_splitter_inc.h:121-134`, entropy refactoring, and regenerated dictionary-entry ordering. No source evidence establishes a major q10 speedup.

For **qualities 5–7**, tag filtering is the substantial new mechanism: compare tags in parallel, enumerate matching slots, then inspect candidates. It trades additional memory for fewer candidate loads/comparisons.

For **qualities 8–9**, H5/H6 remain selected, but their implementation changes: bucket prefetching, four-byte match rejection, and boundary-check restructuring (`hash_longest_match_inc.h:172-250`, `hash_longest_match64_inc.h:173-274`). These are real performance-path changes despite unchanged hasher names.

Shared entropy work includes out-of-line `BrotliBitsEntropy` (`bit_cost.c:18-48`), the new `EstimateEntropy` (`encode.c:245-255`), and constant-reciprocal expressions (`encode.c:452-455`). Compression ratio, exact output, and throughput can change; measured direction and magnitude are **UNVERIFIED**.

**`/arch:AVX2` is not required to activate the new tag hashers.** Their explicit vector operations are:

- `_mm_set1_epi8`
- `_mm_loadu_si128`
- `_mm_cmpeq_epi8`
- `_mm_movemask_epi8`

These are SSE2 operations, selected for MSVC x64 (`matching_tag_mask.h:6-28`). Bucket prefetch uses `_mm_prefetch` (`platform.h:615-621`). No AVX2-specific intrinsic or AVX2/BMI feature gate was found in the audited encoder sources.

`/arch:AVX2` can still affect compiler-generated vectorization and instruction selection under `/O2 /GL /LTCG`. The resulting binary’s instruction requirements and speed difference are **UNVERIFIED** without compilation/disassembly and measurements.

**TZCNT on a CPU without BMI1**

Every encoder invocation found is guarded against zero:

| Call site | Guard |
|---|---|
| `find_match_length.h:29` | `if (x != 0)` at line 28 |
| H58 `hash_longest_match_simd_inc.h:233` | Loop requires `matches > 0` at line 231 |
| H68 `hash_longest_match64_simd_inc.h:260` | Loop requires `matches > 0` at line 258 |

Therefore **zero does not reach `BROTLI_TZCNT64` through these encoder paths**. Under the stated TZCNT-as-BSF behavior on non-BMI1 CPUs, nonzero operands produce the same trailing-bit index; the caller uses that value, not instruction flags.

The existing match-length use already existed in v1.1.0 (`c/common/platform.h:479`, `c/enc/find_match_length.h:30-31`). The new SIMD calls preserve the nonzero requirement. This supports compatibility of these particular calls, not certification of all instructions emitted by an AVX2-targeted build.

**Residual limits of the verdict**

The identified availability risks are allocation pressure, default process exit on OOM, expensive quality-10 work, and conditional debug assertions. No newly reachable Critical defect was established. The omitted ring-tail repair addresses an inherited state; exploitability or output dependence under the supplied restricted pattern was not demonstrated.

Actual DLL build definitions, stream-error propagation, runtime correctness, performance, and generated CPU instructions remain **UNVERIFIED**. The verdict is a completed source audit, not build or production acceptance.

---
status: ok
result: findings
findings: C=0 O=3 P=0
freshness: "Exact release tags; local origin/master 089e71983611a42643d75194fedfde086c5e58af; no network refresh"
target_head: db24a98aed38a16de78cc05ca15cdd8dc2a0d92d
summary: "No identified reachable Critical encoder regression; inherited OOM exit, new q5-7 memory overhead, and conditional assertion regression."
ran_commands:
  - "git status --short"
  - "git rev-parse v1.1.0 v1.2.1 origin/master"
  - "git diff --stat v1.1.0 v1.2.1 -- c/enc c/common c/include"
  - "git log --format='%h %cs %s' v1.2.1..origin/master -- c/enc c/common c/include"
  - "git log --right-only --cherry-pick --no-merges --format='%h %cs %s' v1.2.1...origin/master -- c/enc c/common c/include"
  - "git diff v1.2.0 v1.2.1 -- c/enc c/common c/include"
  - "git show and git grep for cited revisions and paths"
  - "Read-only PowerShell comparisons of generated dictionary initializers and per-bucket entries"
prompt_mode: full
written_at: "2026-10-27"
---