# Read performance against nanoparquet

Owns the v0.2.0 read-performance work: the target, the measured evidence, the
root causes, and the ordered plan. Benchmark method, reference workloads, and
the regression threshold stay in [`../bench/README.md`](../bench/README.md);
this document says what to change and why.

## Target

**Match or beat nanoparquet on read, on the workloads where qio is behind.**

**Status: met on the shapes this document set out to fix, and the target has
since been shown to be the wrong shape of question.** Steps 1-4 and 6 landed in
v0.1.0; step 5 was measured and declined. See "Where this ended up" below, and
then "What the generated benchmarks could not see", which is the part worth
reading first if you are picking this up cold.

The original framing, kept because the reasoning still applies:

| gap | ratio then | cause | steps |
|---|---:|---|---|
| dictionary-encoded text | 1.5x-2.6x | index decode and string materialization | 1-3 |
| plain-encoded text | 1.14x-1.22x | per-row UTF-8 validation | 4 |

The parallel decode qio already has is what should take it *past* parity rather
than merely to it, since nanoparquet is single-threaded by design (confirmed:
no threading primitives anywhere in its sources).

## Where this ended up

1,000,000 rows, both builds installed at -O2, median of 9, same machine state.

| workload | before | after | nanoparquet | ratio |
|---|---:|---:|---:|---|
| dictionary text, 200 values (8 bits) | 0.0140 | 0.0090 | 0.0100 | 1.40x -> **0.90x** |
| dictionary text, 257 values (9 bits) | 0.0170 | 0.0110 | 0.0100 | 1.70x -> **1.10x** |
| dictionary text, 65536 values (16 bits) | 0.0460 | 0.0200 | 0.0200 | 2.30x -> **1.00x** |
| dictionary text, 65537 values (17 bits) | 0.0510 | 0.0220 | 0.0200 | 2.55x -> **1.10x** |
| plain text, all distinct | 0.1340 | 0.1310 | 0.1130 | 1.13x -> 1.16x |
| doubles | 0.0040 | 0.0040 | 0.0070 | **0.57x** |

The ratio column is flat as well as lower, which was the actual criterion: a
change that lowered every width equally would not have addressed the kernel
gap.

Two estimates in this document were wrong, and the corrections are recorded at
their steps rather than quietly fixed. Step 1 predicted 28% and less benefit at
high cardinality; it delivered 47% there, the largest win, because the address
cache it replaced held only 512 entries and switched itself off above that.
Step 4 predicted plain text would drop below parity from a "28% validation
cost"; that figure came from a pre-step-1 profile and over-attributed, and
plain text is now known to be 73% Rf_mkCharLenCE, which nanoparquet pays too.

## Where qio stands

1,000,000 rows, single column, snappy, four row groups, Apple silicon, 8 cores.
Median seconds to *materialized* data, so ALTREP deferral is charged fairly.

| workload | qio | nanoparquet | ratio |
|---|---:|---:|---:|
| doubles | 0.006 | 0.012 | **0.50x** |
| plain text, all distinct | 0.151 | 0.132 | 1.14x |
| dictionary text, 500 values | 0.028 | 0.015 | 1.87x |

The dictionary case degrades with cardinality, in steps that land exactly at
powers of two. This was predicted from carquet's kernel coverage before it was
measured, which is why it is trustworthy:

| distinct values | index bit width | qio | nanoparquet | ratio |
|---:|---:|---:|---:|---:|
| 200 | 8 | 0.0230 | 0.0150 | 1.53x |
| 256 | 8 | 0.0250 | 0.0150 | 1.67x |
| 257 | 9 | 0.0280 | 0.0160 | 1.75x |
| 65536 | 16 | 0.0710 | 0.0310 | 2.29x |
| 65537 | 17 | 0.0790 | 0.0300 | 2.63x |

The steps at 8 -> 9 and 16 -> 17 bits are ~12% each. They are real but
secondary: qio is already 1.53x behind at width 8, where carquet's fast kernel
*is* used. Most of the gap is constant across widths.

## Profile

`sample(1)` over a read loop, 1,000,000 rows, cardinality 200 (bit width 8, so
carquet's fast path). 3313 samples in `qio_parquet_collect`.

| component | share |
|---|---:|
| qio scatter loop -- `SET_STRING_ELT` | 20% |
| qio scatter loop -- address-cache hash and probe | 20% |
| carquet -- RLE index decode | 20% |
| GC triggered by result allocation | 11% |
| carquet -- dictionary gather into `carquet_byte_array_t` | 8% |
| carquet -- definition levels, page memmove | 6% |
| carquet -- snappy decompress | 0.3% |

Decompression is noise. The cost is index decoding and string materialization,
in roughly equal parts.

The 11% GC share is inflated by the measurement loop, which allocates a
1,000,000-element `STRSXP` repeatedly. Treat the other figures as slightly
understated rather than treating GC as a target.

The plain-text profile is different and should not be optimized with the same
changes: there `Rf_mkCharLenCE` is 38% and `qio_check_string_bytes` (UTF-8
validation) is 28%.

## Root causes

Three, each confirmed by reading both implementations rather than inferred from
timings alone.

### 1. Dictionary text is expanded, then re-deduplicated

carquet materializes every row into a 16-byte `carquet_byte_array_t`
(16 MB per million rows), and
[`qio_scatter_dense_column()`](../src/qio_file.c) then walks those structs
hashing each *pointer* to rediscover the 200 distinct values it already had.
qio pays to destroy the dictionary and pays again to rebuild it.

nanoparquet keeps the indices, builds one `STRSXP` of the dictionary, and
gathers (`RParquetReader.cpp`, `convert_column_to_r_ba_string`):

```cpp
SEXP tmp = PROTECT(Rf_allocVector(STRSXP, dict_len));
for (uint32_t i = 0; i < dict_len; i++) {         // one mkChar per distinct value
  SET_STRING_ELT(tmp, i, Rf_mkCharLenCE(...));
}
while (didx < end) {                               // direct index gather
  SET_STRING_ELT(x, from++, STRING_ELT(tmp, *didx++));
}
```

carquet already supports exactly this: `preserve_dictionaries` in the
batch-reader config ([`carquet.h`](../src/carquet/carquet/carquet.h) ~1707)
returns `uint32` indices plus the dictionary. **qio has never set it.**

Note that `roadmap.md` section 3 marks "materialize dictionary text
efficiently" as done. It refers to the address cache, which was a real
improvement over per-row `Rf_mkCharLenCE` (-46% at the time). The profile now
shows that cache is itself the 20%. The item should be reopened, not treated as
settled.

### 2. Bit-unpack kernels are narrow and sparse

| | carquet | nanoparquet |
|---|---|---|
| widths with a kernel | 1-8 and 16 | all of 1-32 |
| values per call | 8 | 32 |
| fallback for other widths | byte-at-a-time loop with `%` per byte | none needed |
| per-call overhead | `carquet_dispatch_get_bitunpack8_fn()` including `DISPATCH_ENSURE_INIT()` | none, unrolled |

nanoparquet vendors `fastpforlib` (Apache-2.0, ~2600 lines), which has 124
fully unrolled `__fastunpack1`..`__fastunpack32` routines.

The per-call dispatch lookup alone is 6% of carquet's RLE decode: it runs once
per 8 values and is pure overhead.

### 3. RLE literal runs are copied one value at a time

carquet unpacks into a small scratch buffer and then copies out with three loop
conditions per value ([`rle.c`](../src/carquet/encoding/rle.c) ~212):

```c
while (read < count && dec->bitpack_pos < dec->bitpack_count &&
       dec->run_remaining > 0) {
    output[read++] = dec->bitpack_buffer[dec->bitpack_pos++];
    dec->run_remaining--;
}
```

nanoparquet unpacks the whole literal run straight into the destination
(`RleBpDecoder.h`, `GetBatch`): `BitUnpack<T>(values + values_read,
literal_batch)`. No scratch, no per-value copy.

### Also: qio never writes dictionary-encoded text

Separate from reading, and it makes qio's own files the worst case. The same
500-value column: qio writes 283 KB, arrow writes 49 KB -- **5.7x**. Reading a
qio-written text column therefore lands on the plain path, where per-row
`mkCharLenCE` and UTF-8 validation dominate.

carquet's writer supports it (`column_writer.c` marks `BYTE_ARRAY` dictionary
eligible); qio calls `carquet_writer_options_init()` and never sets a per-column
encoding via `carquet_writer_set_column_encoding()`.

## Plan

Ordered by measured value per unit of risk. Each step states its own exit
gate. **No step lands without before/after medians on an idle machine**, per
the working rules in `../bench/README.md`.

### Step 0 -- extend the comparison harness (prerequisite) -- **done**

`bench/compare-readers.R` used one text cardinality, which hid the cliff that
turned out to be a real effect. It now sweeps 200, 257, 65536 and 65537,
asserts each fixture actually carries a dictionary page, and reports a ratio
column that a real fix must *flatten* rather than merely lower.

Landed in `33e4d6c`. The sweep reproduces the table above; note that it needs
rows to resolve, and a small `--rows` run understates the effect rather than
disproving it.

### Step 1 -- materialize dictionary text from indexes

The largest single win and the one that reaches the target.

Read via carquet's `preserve_dictionaries` path, build the dictionary `STRSXP`
once per column chunk, gather by index. Removes the dictionary gather (8%) and
the entire address cache (20%).

Constraints that make this harder than it looks, and which the design must
address before any code is written:

- **A column chunk can mix encodings.** Arrow writes a dictionary page and then
  falls back to PLAIN for later pages in the same chunk; carquet errors out in
  preserve mode when that happens (`page_reader.c` ~967, ~1103). A fallback to
  the current path is mandatory, per page, not per column.
- **`qio_apply_plan()` must keep `read_parquet()`, `collect()`, and
  `walk_batches()` consistent** (see `../CLAUDE.md`). A faster path used by only
  one of the three is a defect, not an optimization.
- **UTF-8 validation moves but must not be skipped.** Validate the dictionary
  once per chunk instead of once per row. That is a speedup *and* a
  correctness-preserving change; dropping validation is not on the table.
- The address cache stays for the plain path, where it already pays for itself
  and switches itself off when it does not.

Expected: -28% on the dictionary workloads, which is roughly parity
(0.023 -> ~0.017 against nanoparquet's 0.015).

Exit: dictionary workloads at ratio <= 1.1x; the full interoperability corpus
unchanged; a fixture with mid-chunk encoding fallback in
`tests/testthat/parquet/`.

### Step 2 -- fix the RLE literal-run copy

Unpack literal runs directly into the destination and delete the per-value copy
loop. Hoist the dispatch lookup out of the per-8-values path.

Smallest change here, and it helps every RLE consumer -- dictionary indices,
definition levels, booleans -- not only text.

Expected: the dispatch hoist alone is ~6% of the RLE decode (~1% overall); the
direct-unpack is worth more but is not separately measured yet. Measure both
independently; do not land them as one commit.

Exit: measured gain on `read-string_low_cardinality` and no regression on
`read-numeric_nulls`, which exercises the same decoder for definition levels.

### Step 3 -- widen bit-unpack kernel coverage

Add unrolled kernels for widths 9-15 and 17-32, and unpack 32 values per call
rather than 8.

Two ways to get there, and the choice needs deciding before work starts:

| option | pros | cons |
|---|---|---|
| Extend carquet's own kernels | fits `VENDORED.md` patch discipline, upstreamable, no new license | ~24 kernels to write and test |
| Vendor `fastpforlib` | proven, complete, already used by nanoparquet | new Apache-2.0 dependency in an MIT package, third bundled license, CRAN `LICENSE`/NOTICE work, and it is C++ in a C codebase |

**Recommendation: extend carquet.** The C++/licensing/CRAN cost of a third
bundled library outweighs 24 mechanical kernels, and a carquet patch is
upstreamable where a vendored library is not. Revisit only if the kernels prove
harder than expected.

Expected: ~12% on widths outside 1-8 and 16, which is where high-cardinality
dictionaries live. Nothing on width <= 8.

Exit: `test_bitunpack_wide`-style verification of every new kernel against the
scalar unpacker, plus the cardinality sweep from step 0 showing the cliff gone.

### Step 4 -- SIMD UTF-8 validation

The only step that addresses the *plain*-text gap. Steps 1-3 do nothing for it:
they are all about dictionary indices, and a plain page has none.

`qio_check_string_bytes()` is **28% of a plain-text read** -- a scalar
`qio_utf8_invalid_at()` walk plus a `memchr` for embedded nuls, per value.
nanoparquet does neither: `convert_column_to_r_ba_string_nodict_nomiss` calls
`Rf_mkCharLenCE(..., CE_UTF8)` on the raw bytes and moves on.

**This is a feature qio has and nanoparquet does not**, not overhead to delete.
`Rf_mkCharLenCE(CE_UTF8)` does not check, so without the walk a column of
arbitrary bytes yields CHARSXPs claiming an encoding they do not have, failing
somewhere else later instead of here with a column and row. `?qio-types`
documents the guarantee. Removing it to win a benchmark would be trading a
correctness property for a number.

Accelerate it instead. SIMD UTF-8 validation is well-trodden and runs at
GB/s; carquet already carries NEON and SSE/AVX2 infrastructure to model it on.
Validate a whole page's byte range in one pass rather than per value, so the
`memchr` folds into the same sweep.

Expected: most of the 28%, which takes plain text from 1.14x to comfortably
under parity. Nothing on dictionary columns after step 1, where validation has
already moved to once per dictionary.

Exit: plain-text workloads at ratio <= 1.0; the invalid-UTF-8 and embedded-nul
fixtures still fail with the same messages, byte offset included; a
differential test against the scalar validator over random and adversarial
byte sequences (overlong forms, surrogate halves, truncated sequences,
above U+10FFFF).

### Step 5 -- parallelize text columns

`qio_file.c` keeps all `BYTE_ARRAY` work on the main thread because interning
and the write barrier are R API. But only `SET_STRING_ELT` (20%) truly needs
the main thread. After step 1, the index decode is worker-safe: workers produce
`uint32` indices into private scratch, the main thread gathers.

This is the step that goes *past* nanoparquet rather than matching it.

Expected: up to the ~50% of a text read that is not R API, bounded by
Amdahl and by the existing 50,000-row threshold for private readers.

Exit: a measured gain at 8 threads with no change at `threads = 1`; clean under
the sanitizer and helgrind workflows.

### Step 6 -- write dictionary-encoded text

Set `CARQUET_ENCODING_RLE_DICTIONARY` for `BYTE_ARRAY` columns. Roughly ten
lines. 5.7x smaller files on low-cardinality text, and it puts qio-written files
on the fast read path.

**This one is gated on verification, not on measurement.** qio has never
exercised carquet's dictionary encoder, and this project has already found a
carquet encoder that silently corrupted output (BYTE_STREAM_SPLIT, recorded in
`../bench/README.md`). Round-trip the full type matrix and verify with arrow and
pyarrow as independent oracles before trusting it.

Exit: independent-oracle verification across the type matrix; a size and time
figure for each reference workload; a `NEWS.md` entry, since it changes default
output.

## Sequencing, and what actually happened

This document originally deferred every step to v0.2.0, on the grounds that
step 1 restructures text materialization and invalidates phase 8. **The
maintainer decided to include them in v0.1.0 instead**, and phase 8 was re-run
afterwards rather than skipped.

| step | outcome | commit |
|---|---|---|
| 0, comparison harness | done | `33e4d6c` |
| 1, dictionary text from indexes | done | `9cc56cc` |
| 2, RLE literal-run copy | done, two commits | `b6a1209`, `25cd8f7` |
| 3, bit widths 9-32 | done, one generic routine rather than 24 kernels | `29482b3` |
| 4, ASCII skip when validating UTF-8 | done | `c44a84d` |
| 5, parallelize text columns | **measured and declined** | — |
| 6, write dictionary-encoded text | done | `d38d03d` |

**Step 5 was declined on measurement, not on schedule.** Profiling after steps
1-3 put only ~20% of a dictionary read outside the R API: SET_STRING_ELT 30%,
the gather loop 27%, allocation and GC 18%. Amdahl at eight threads gives a
1.21x ceiling, not the ~1.8x this document assumed. Steps 1-3 succeeding is
what consumed step 5's value -- they removed the work threads would have
absorbed. Against a 1.21x ceiling sits the most dangerous change in the plan,
in the code path where step 1 had already introduced a heap-corrupting buffer
overrun. Revisit only if the parallelizable fraction grows again.

## Closing the residual gap

Stages 1-4 and 6 landed and dictionary text reached parity. What remains was
measured rather than assumed, and splits into three findings with three
different owners. **Only one of them is carquet's**, which is the answer to
"is the gap the vendored library?": on dictionary text, where decoding actually
dominates, carquet plus its patches now matches or beats nanoparquet.

Measured at 1,000,000 rows, one column of distinct 11-byte strings, both builds
installed at -O2:

| file | qio | nanoparquet | ratio |
|---|---:|---:|---:|
| written by qio (PLAIN, no dictionary page) | 0.1290 | 0.1120 | 1.15x |
| written by arrow (dictionary page, falls back to PLAIN) | 0.1430 | 0.1150 | 1.24x |

### Finding 1 -- the abandoned attempt costs ~10%, and it is qio's design

Apache Arrow emits a dictionary page even for a column of a million distinct
values: it begins dictionary-encoding, outgrows its page limit, and falls back
to PLAIN partway through the chunk. qio sees the dictionary page in the footer,
attempts the index path, meets a PLAIN page, and throws the work away to re-read
the whole chunk on a fresh column reader.

Isolated with a build that can disable the attempt, same session, control
included:

| file | attempt on | attempt off | delta |
|---|---:|---:|---|
| arrow-written, dictionary falls back | 0.1460 | 0.1320 | **-10%** |
| qio-written, no dictionary page | 0.1300 | 0.1300 | 0%, the control |
| dictionary that does not fall back | 0.0110 | 0.0130 | attempt **saves** 15% |

nanoparquet does not pay this. It splits a column chunk into *chunk parts* --
contiguous runs of pages that are all dictionary-indexed or all not -- and
materializes each part with the right strategy, never re-reading
(`RParquetReader.cpp`, `alloc_data_page`, whose comment cites this exact Arrow
behaviour).

qio cannot do that today because `carquet_column_read_batch()` in preserve mode
fails the whole read rather than stopping cleanly at the page boundary. That is
an API limitation, not a decoding-speed one.

**Strategy.** Give the caller the boundary instead of an error, in two parts:

1. *carquet*: when preserve mode reaches a non-dictionary page, return the
   values decoded so far and leave the reader positioned at that page, with a
   distinguishable status rather than -1. The refusal added in the stage 1 work
   already identifies the exact point; it currently discards the position.
2. *qio*: on that status, flip the reader to `preserve_dictionary = false` and
   continue from where it stopped, scattering the remainder through the
   materializing path. The dictionary `STRSXP` built for the first part stays
   valid, because its CHARSXPs are copies.

The risk is that a reader flipping mode mid-stream must resize its decode
buffer, and getting that wrong is exactly the 4x overrun that stage 1 hit.
`decoded_value_size` already exists for this, but it has never been exercised
mid-chunk. Treat it as the primary hazard, not an afterthought.

Expected: the 10% back on arrow-written text, and nothing elsewhere. This does
**not** close the 1.15x on qio-written text, which is finding 2.

### Finding 2 -- 73% of a plain-text read is R's, not qio's

Profiling plain text after stage 4: `Rf_mkCharLenCE` 73%, decode 8.5%,
allocation 7%. That is R interning a million distinct strings into its global
CHARSXP cache. nanoparquet pays it identically; there is no R API that produces
a character vector without it.

This is why dictionary text reached parity and plain text did not. In the
dictionary case `mkCharLenCE` runs once per *distinct* value, so the decode work
stages 1-3 optimized is most of the cost. In the plain case it runs once per
*row* and decode is under a tenth of the total.

**Strategy: confirm the floor, then stop.** Measure the cost of building a
1,000,000-element `STRSXP` from distinct strings with no I/O at all. If that
figure is close to both readers' times, the remaining difference is not worth
chasing and the ceiling should be written down rather than re-attacked.

The one real lever is not making the strings at all: returning a dictionary
column as a `factor` -- integer codes plus a levels vector -- costs one
`mkCharLenCE` per distinct value instead of per row. nanoparquet already
carries the dictionary for this (`facdicts`). That is an API change, not an
optimization, and belongs with the v0.2.0 result-type decisions rather than
here. It also does nothing for genuinely distinct text.

Explicitly rejected: returning an ALTREP character vector that defers
materialization. It would win this benchmark by not doing the work, which is
the trap `bench/compare-readers.R` was built to expose in arrow. qio
materializes eagerly and should keep saying so.

### Finding 3 -- roughly 5% is unattributed

After removing the fallback penalty, qio-written plain text is 1.15x, and decode
is only 8.5% of that read, so carquet cannot account for the difference. The
remainder is spread across allocation, the scatter loop, and per-string call
overhead.

**Strategy: attribute it before acting on it.** It was inferred by subtraction,
which is exactly how the "28% validation cost" estimate that stage 4 disproved
was arrived at. Profile the plain path against nanoparquet's directly, with the
same fixture and the same sampling, and only then decide whether anything is
worth changing.

### Test gaps closed before any of this is implemented

The reader has three paths for a text column chunk -- dictionary indices, an
abandoned attempt with a re-read, and no attempt -- and **all three return
byte-identical data**. Every test in the suite would therefore pass unchanged if
a regression sent every column down the slowest path. Diagnosing which branch
ran during stage 1 needed a temporary `fprintf` build, which is the clearest
possible evidence that the tests could not see it.

Made observable instead, before changing the implementation:

- `qio_read_path_counters()` (internal, undocumented) reports how many chunks
  took each path and resets on read. Incremented only on the main thread, where
  BYTE_ARRAY columns already run.
- `test-external.R` now asserts the path per fixture: four dictionary chunks for
  `dict_nulls.parquet`, one fallback for `dict_fallback.parquet`, two dictionary
  and one declined for `string_encodings.parquet`, and declined-only for
  `delta_encodings.parquet` -- the shape that overran a buffer before carquet
  learned to refuse preservation.
- A batch-size test asserts that splitting a chunk never pushes it onto the
  fallback path, which a per-batch dictionary reload would do while still
  returning correct data.

Finding 1 changes which path runs for a mixed chunk. When it lands, the
`dict_fallback.parquet` expectation must change from one fallback to a new
"switched mid-chunk" outcome, and that change is the point: it is what proves
the optimization is live rather than silently inert.

## What the generated benchmarks could not see

**Read this before planning any further read work.** Everything above was
measured with `bench/compare-readers.R`, which generates its own data. It can
only contain what someone thought to generate, and what nobody thought to
generate was a real file.

The first one ever pointed at qio -- January 2023 NYC taxi trip data, 3,066,766
rows, 19 columns, GZIP, every column dictionary-encoded -- read in **83.2
seconds** against arrow's 0.195 and nanoparquet's 0.541. Every value was
correct. That is 426x, on a mainstream public dataset, at a point when the
generated benchmarks showed qio at or near parity everywhere.

Timing each column separately put 85 of those 83 seconds in two of nineteen
columns. Both were `TIMESTAMP`, and the cost was not in carquet at all: a
profile showed no `qio.so` frames whatsoever. `qio_as_posixct()` re-anchored a
non-UTC-adjusted timestamp by formatting every value to text and reparsing it,
in R.

### The correctness bug underneath the slowness

Worse than the 42 seconds, and it would not have been found by profiling.
`as.POSIXct.character` picks a format by requiring **every** value to parse. A
civil time inside a spring-forward gap has no instant in the target zone, so
`strptime` returns NA for it, which rejected `"%Y-%m-%d %H:%M:%OS"` and fell
through to `"%Y-%m-%d"`. That parses everything -- so **one unrepresentable
value silently reduced every other value in the column to midnight**.

Reproduced on the build from before any of this work, so it shipped. Reaching
it needs `tz` set to a DST-observing zone; the default of UTC has no gaps.
Fixed in `e6c7d95`: a value with no instant in `tz` is now NA on its own
account and its neighbours are untouched, and the whole file reads in 0.209 s.

### The pattern, and the audit it prompted

Per-value work in R rather than over the vector. Auditing every converter for
the same shape found three more:

| converter | before | after | commit |
|---|---:|---:|---|
| local `TIMESTAMP` | 42.7 s/1M | 0.106 s | `e6c7d95` |
| `UUID` | 22.8 s/1M | 0.339 s, moved into C | `330d601`, `ee9531b` |
| `FLOAT16` | 1.18 s/1M | 0.276 s | `330d601` |
| binary `DECIMAL` | 1.06 s/1M | 0.903 s | `b8f370b` |

An ordinary 1M-value column reads in roughly 0.05 s, so `UUID` cost several
hundred times one of those.

The shared hazard when vectorizing these is nulls: a `NULL` element contributes
nothing to `unlist()`, so reshaping without excluding nulls first silently
shifts every later value into the wrong slot. Every one of these tests puts a
null **first** for that reason.

### What follows from it

- `bench/real-file.R` exists now, and its per-column table with a `SLOW` marker
  at 20x the median column is the automation of the diagnosis above. The
  threshold was checked against the pre-fix build, where it fires on exactly
  those two columns and nothing else.
- **Six stages of read optimization were worth nothing on that file.** They were
  not wasted -- dictionary text is genuinely at parity now -- but the ranking
  was set by generated shapes, and the single largest defect was somewhere the
  generated shapes could not reach.
- The measured finding rate is four defects from one real file. There is no
  basis for assuming the second one finds nothing. Run `bench/real-file.R`
  against files from other writers -- Spark, DuckDB, pandas -- before ranking
  any further read work by these numbers.

## Out of scope

Recorded so they are not re-proposed without new evidence.

- **Statistics-driven no-null path** and **backward in-place expansion.** Both
  measured and declined in phase 4, ceilings of 10.5% and 3.2%. nanoparquet
  does implement the second one (`convert_column_to_r_ba_string_miss`), which
  is worth knowing but does not change the measured ceiling on qio's side.
- **Dropping UTF-8 validation.** It is 28% of the plain-text read, and it is
  why qio rejects invalid UTF-8 and embedded nuls with the column and row.
  Moving it (step 1) and accelerating it (step 4) are in scope; removing it is
  not. nanoparquet skips it entirely, so any comparison on plain text is
  measuring qio doing strictly more work -- that is a defensible trade, but it
  has to be stated rather than optimized away.
- **Compression codecs.** Snappy decompression is 0.3% of a dictionary read.
  There is nothing here.
