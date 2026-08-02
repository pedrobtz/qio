# qio benchmarks

Reproducible read and write benchmarks, and the recorded v0.1.0 baseline.
`bench/` is excluded from the source package by `.Rbuildignore`; nothing here
ships, and no test loads anything from this directory.

Ordered work and exit gates live in [`../.agents/plan.md`](../.agents/plan.md).
This file owns the benchmark method, the reference workloads, and the
regression threshold.

## Two benchmarks, two questions

`benchmark.R` is the reference. It answers "did this commit make qio slower on
my machine", with large workloads, per-case tolerances measured on a quiet
machine, and `--compare` to gate a change against a saved baseline. It needs
`arrow` once to generate fixtures, and it is only meaningful on a quiet machine.

`ci-benchmark.R` answers a narrower question, because a shared runner cannot
answer the first. It:

- needs nothing but qio and base R, generating its own fixtures. That became
  possible only when `write_parquet(row_group_size =)` landed; before it, a
  multi-row-group fixture had to come from another writer.
- prints a table, writes one into the GitHub job summary, and saves a CSV, so
  the trend is visible across commits;
- **does not gate on performance**, because the spread recorded below on an idle
  local machine is 12-21%, and a shared runner is worse. A percentage threshold
  there fails on noise often enough to be ignored, which is worse than having no
  gate at all;
- fails only on `--max-seconds`, a ceiling high enough that only a hang or an
  order-of-magnitude regression reaches it.

```sh
Rscript bench/ci-benchmark.R                        # print a table
Rscript bench/ci-benchmark.R --rows 1000000 --reps 7
Rscript bench/ci-benchmark.R --out results.csv --max-seconds 60
```

Run by `.github/workflows/benchmark.yml` on every pull request, on pushes to the
default branch, and on demand with `rows` and `reps` inputs.

## Commands

```sh
Rscript bench/benchmark.R                          # run all, print a table
Rscript bench/benchmark.R --save baseline          # also save results/<tag>.csv
Rscript bench/benchmark.R --compare baseline       # compare with a saved run
Rscript bench/benchmark.R --reps 20 --filter read- # subset, more repetitions
```

`--compare` exits non-zero if any case regresses past the threshold, so it can
gate a change without a human reading the table.

## Comparing against other readers

`compare-readers.R` times qio against `arrow` and `nanoparquet`. Both packages
are needed to run it and neither is a qio dependency; like the rest of `bench/`,
it never ships and no test loads it.

```sh
Rscript bench/compare-readers.R
Rscript bench/compare-readers.R --rows 2000000 --reps 7 --out compare.csv
```

A comparison is a claim about someone else's software, so the script is built to
be refutable rather than flattering:

- Files are written by **both** qio and arrow, so a reader tuned for its own
  writer's layout shows up as a difference between the two writers rather than
  as a win.
- Readers must **agree before they are timed**. Readers that disagree are not
  doing the same work, and the script stops instead of reporting it.
- Only types all three map identically are used. Where the mappings differ --
  64-bit integers most obviously -- a comparison measures behavior, not speed.
- Thread counts are printed. nanoparquet is single-threaded by design, so its
  column is a different trade-off rather than simply a slower one.

**The trap that makes this hard: arrow's R package uses ALTREP, so
`read_parquet()` can return before the values exist**, charging the cost to
whoever first touches them. On a 500,000-row string column, arrow's read
measured 0.011s while forcing the same data measured 0.048s; qio materializes
eagerly, so it measured 0.042s and 0.045s. Timing the bare call compares qio
doing all the work against arrow doing a fraction of it, and reported qio as 9x
slower on text where the forced figures are close to level. Every case is
therefore timed to *materialized* data, by summing over every column after
reading, which costs all three readers the same.

### Where qio stands

Measured at 200,000 rows, snappy, four row groups, on one Apple silicon laptop
with 8 cores. Median seconds to materialized data, files written by qio:

| workload | qio | arrow | nanoparquet |
|---|---:|---:|---:|
| `numeric` | 0.0060 | 0.0050 | 0.0070 |
| `text_dictionary` | 0.0390 | 0.0220 | 0.0150 |
| `text_unique` | 0.0460 | 0.0290 | 0.0220 |
| `mixed_nulls` | 0.0270 | 0.0170 | 0.0160 |

qio is 1.2x to 2.6x slower than the best alternative on these shapes, closest on
dense numerics and furthest on dictionary-encoded text. nanoparquet is fastest
on text while single-threaded, which is the clearest signal in the table and the
first thing to look at if read performance becomes a priority.

Nothing qio documents claims otherwise. Recorded here so the position is known
rather than assumed, and so a future optimization has a starting point.

## Method

- Metric: **median wall time** over `--reps` timed repetitions (default 10),
  after `--warmup` untimed ones (default 2). `gc()` runs before each timed
  repetition.
- The table also reports `min` and the interquartile range so noise is visible.
  A change that moves the median but not the min is usually noise.
- Compare only runs from the same machine, build configuration, and fixture
  set. The saved CSV records R version, platform, core count, and commit.

## Fixtures

Generated under `bench/fixtures/` on first use and reused afterwards; delete
the directory to rebuild. Both the data and the row-group layout are
reproducible from `bench/workloads.R` and a fixed seed.

Read fixtures are written with **Apache Arrow**, not with qio. Two reasons:

1. When these fixtures were designed, qio's writer had no way to set a row-group
   boundary: it flushed only when carquet's byte target was exceeded (128MB
   default), so a qio-written fixture of this size was a *single* row group.
   Benchmarking against that would have exercised none of the multi-row-group
   paths — parallel collect schedules one task per row group per column, and
   row-group projection would be a no-op. Phase 6 added
   `write_parquet(row_group_size =)`, so that constraint is gone; reason 2 is
   why the fixtures still come from Arrow.
2. Reading files produced by a mainstream writer is what users actually do.

`arrow` is therefore needed **once**, to generate fixtures. It is not a package
dependency and no test uses it. Write benchmarks always use qio's writer.

## Reference workloads

Later phases must not regress these. Each names what it protects.

| Workload | Rows | Row groups | Protects |
|---|---|---|---|
| `numeric` | 2,000,000 | 8 | Numeric decode into R memory, parallel collect, dense scatter |
| `numeric_nulls` | 2,000,000 | 8 | Nullable def-level scatter (~10% nulls per column) |
| `string_low_cardinality` | 1,000,000 | 4 | Dictionary text materialization |
| `string_high_cardinality` | 1,000,000 | 4 | Plain-encoded strings and peak string scratch |
| `mixed` | 1,000,000 | 4 | End-to-end read and write, projection, row-group selection |

Cases built on `mixed` each vary one thing against `collect-buffered`, so a
change can be attributed: `collect-mmap` adds the mapping, `collect-mmap-serial`
removes the worker pool, `collect-projection` and `collect-row-groups` narrow
the read, `walk-batches` swaps in the batch reader.

## Regression threshold

**A case regresses if its median moves more than its tolerance in the slow
direction: 5% by default, 15% for `collect-mmap` and `read-mixed`.**

The tolerances are measured, not chosen by convention. Three full runs of one
commit on one machine gave this per-case spread between the fastest and slowest
run:

| Case | Median spread | Min spread |
|---|---|---|
| `collect-mmap` | 12.1% | 20.9% |
| `read-mixed` | 11.2% | 9.0% |
| `read-numeric_nulls` | 2.6% | 4.6% |
| `read-numeric` | 2.3% | 20.0% |
| `write-numeric` | 2.1% | 0.5% |
| `write-string_low_cardinality` | 1.4% | 0.7% |
| everything else | ≤0.7% | ≤1.7% |

Two conclusions follow, and both are baked into `benchmark.R`:

- **Noise is bimodal.** Every serial case is stable to within 3%, but the two
  cases that run the worker pool vary 11–12% because thread scheduling varies.
  A single 5% gate would report false regressions on exactly those two, so they
  get a 15% tolerance in `QIO_BENCH_TOLERANCE`.
- **The median beats the min.** The min is the noisier statistic here (up to
  20.9% for `collect-mmap`, 20.0% for `read-numeric`), so it is reported for
  context but never gated on.

Rules for using it:

- The gate applies to the **median**, per case. One case regressing is a
  regression, even if the total improves.
- **Compare full runs with full runs.** A `--filter`ed run is measurably faster
  than the same case inside the full suite, so a filtered result must not be
  compared against a full-suite baseline.
- The 15% cases can only catch large regressions. A change aimed at the
  parallel path should also report `collect-mmap-serial` and
  `collect-buffered`, which are stable to 0% and isolate the same work.
- A deliberate trade-off that exceeds a tolerance is allowed, but the change
  must say so and record the measured numbers, per the plan's working rules.
- Re-measure before and after on the same machine and fixtures. Numbers from
  different machines are not comparable and must not be used as evidence.
- **A baseline goes stale.** It is only valid for a machine in the same state
  that recorded it, so an otherwise idle machine is part of the method. If a
  comparison reports improvements the change does not explain, suspect the
  baseline before believing the result, and re-record it.

## Baseline

Re-recorded at the end of phase 3.2. **The phase 0 baseline was discarded**: it
was measured while the machine was busy compiling, so every case was 15-40%
slower than the same commit measures when the machine is idle. Comparing
against it reported large phantom improvements, and worse, would have masked a
real regression -- a 20% slowdown from a true 0.19s still looks "improved" next
to a stale 0.30s.

The lesson is recorded in the rules above: a baseline is only valid for a
machine in the same state that recorded it. Re-record it whenever comparisons
start showing improvements nothing in the change explains.

- R 4.6.1, `aarch64-apple-darwin23`, Darwin/arm64, 8 cores, idle
- 10 repetitions, 2 warmups
- Saved to `bench/results/baseline.csv` (not committed; regenerate with
  `--save baseline`)

| Case | Median (s) | Min (s) | IQR (s) |
|---|---|---|---|
| `read-numeric` | 0.0640 | 0.063 | 0.0010 |
| `read-numeric_nulls` | 0.0680 | 0.066 | 0.0010 |
| `read-string_low_cardinality` | 0.1050 | 0.104 | 0.0023 |
| `read-string_high_cardinality` | 0.2120 | 0.208 | 0.0032 |
| `read-mixed` | 0.0620 | 0.055 | 0.0045 |
| `collect-buffered` | 0.1790 | 0.179 | 0.0007 |
| `collect-mmap` | 0.0675 | 0.061 | 0.0018 |
| `collect-mmap-serial` | 0.1790 | 0.178 | 0.0000 |
| `collect-projection` | 0.0490 | 0.048 | 0.0000 |
| `collect-row-groups` | 0.0460 | 0.045 | 0.0010 |
| `walk-batches` | 0.2405 | 0.240 | 0.0010 |
| `write-numeric` | 0.2440 | 0.241 | 0.0025 |
| `write-string_low_cardinality` | 0.1860 | 0.184 | 0.0010 |
| `write-mixed` | 0.2885 | 0.286 | 0.0028 |

### What the baseline already shows

Two results are worth carrying into phase 4 rather than rediscovering:

- **The speedup is parallelism, not mmap.** `collect-mmap-serial` (0.179) is
  identical to `collect-buffered` (0.179), while `collect-mmap` (0.0675) is 2.7x
  faster than both. Mapping alone buys nothing here; the worker pool buys
  everything. Phase 4 asks whether private-reader parallelism for buffered reads
  is justified -- on this evidence it is worth about 2.7x for every persistent
  handle, since `parquet_open()` defaults to `mmap = FALSE`.
- **`walk_batches()` is the slowest way to read the same file.** 0.2405 against
  0.179 for `collect-buffered`, so the batch reader costs roughly 34% more than
  the direct column path for a full pass.

Neither is a defect; both are starting points with numbers attached.

## Accepted trade-offs

Deliberate changes that moved a case past its tolerance, with the measured
numbers, per the rules above.

- **Bounded string scratch, phase 4.** Reading string and binary columns in
  `batch_size` chunks costs `read-string_low_cardinality` **+6.6%**
  (0.1060 -> 0.1130 s, measured by A/B of the same commit with and without the
  change). In exchange, peak scratch stops scaling with the largest row group
  and becomes a property the caller controls: on a 2-million-row file peak heap
  fell from a flat ~81 MB at every `batch_size` to 67 MB at 16k rows, rising to
  81 MB only when `batch_size` reaches the row-group size. The cost is
  recoverable later by materializing dictionary text from indexes, which is
  the phase 4 item that targets exactly this workload.

  A caution for anyone re-measuring: sweeping `batch_size` does **not** isolate
  this, because the chunk is `min(batch_size, rows in the row group)` and the
  reference fixtures use 250k-row groups. Every point in such a sweep is
  already chunked, which is why it looks flat. Compare against a build without
  the change instead.

## Buffered reads are now parallel

Measured on `mixed.parquet`:

| | before | after |
|---|---|---|
| buffered, serial decode (the `parquet_open()` default) | 0.181 s | **0.063 s** |
| memory-mapped, serial decode | 0.179 s | 0.179 s |
| memory-mapped, parallel decode | 0.067 s | 0.067 s |

Mapping never bought anything on its own; the entire gap was the worker pool,
which used to run only for mapped readers. Buffered handles now give each
worker a private `carquet_reader_t`, so the default handle decodes in parallel
too. Only above 50,000 selected rows, since each private reader re-parses the
footer.

## Cumulative effect of phase 4

Against the baseline recorded at the end of 3.2, on the same machine:

| Case | before | after | |
|---|---|---|---|
| `collect-buffered` | 0.1810 | 0.0415 | -77% |
| `read-string_low_cardinality` | 0.1130 | 0.0615 | -46% |
| `read-mixed` | 0.0680 | 0.0440 | -35% |
| `read-string_high_cardinality` | 0.2180 | 0.2195 | +0.7% |

Two changes compound: buffered handles decode in parallel, and repeated
dictionary values are interned once instead of once per row. The
high-cardinality column is the control -- it has no repeated values to cache
and no dictionary to exploit, so it should not move, and does not.

## Measured and declined

Two phase 4 optimizations were gated on showing a useful improvement, and did
not. Recorded so they are not re-proposed without new evidence.

| Idea | What it would remove | Ceiling |
|---|---|---|
| Statistics-driven no-null path | definition-level decoding when statistics prove no nulls | 10.5% |
| Backward in-place expansion | one copy from worker scratch into the R vector | 3.2% |

Both ceilings come from a synthetic single-column file of 2,000,000 doubles,
which maximizes their share; the same 2,000,000 doubles read 0.0170 s as
REQUIRED against 0.0190 s as OPTIONAL-with-no-nulls, and a `memcpy` of the
column is 0.0006 s.

Beware the obvious proxy for the second one: timing `y[] <- x` in R gives
0.0050 s, eight times the real `memcpy`, and would have made a 3% idea look
like a 26% one.

## Float encoding, resolved

Phase 5 briefly forced PLAIN encoding for `FLOAT` and `DOUBLE` to avoid a
corrupting BYTE_STREAM_SPLIT encoder, which cost `write-numeric` 50% in time
and 38% in size. The encoder is now fixed instead, so that trade-off is gone:

| | time | size |
|---|---|---|
| broken encoder (corrupt output) | 0.236 s | 31.66 MB |
| PLAIN workaround | 0.354 s | 43.61 MB |
| fixed encoder | **0.295 s** | **31.66 MB** |

Size is fully recovered and time is 17% better than the workaround. It remains
above the broken encoder because a correct BYTE_STREAM_SPLIT has to transpose
the page once, which that version skipped by producing garbage; there is no
valid baseline below 0.295 s here.

Restoring the encoding changes every workload with a float column, not just
`numeric`, and the direction depends on the data:

| Workload | time | size |
|---|---|---|
| `write-numeric` (structured doubles) | -14.9% | 43.61 -> 31.66 MB |
| `write-mixed` (random doubles) | +5.9% | 23.51 -> 22.96 MB |
| `write-string_low_cardinality` (random doubles) | +9.2% | 13.50 -> 12.95 MB |

Byte-splitting only pays for its transpose when the values share structure, so
random doubles get the cost and little of the benefit. Files are smaller in
every case. Accepted: this is what the format's own encoding selection does,
and what Apache Arrow writes by default. Choosing encodings per column is part
of the writer configuration deferred to v0.2.0.

## Not measured yet
- **Compression codecs.** Everything here is Snappy, qio's default. Codec
  comparisons belong with the phase 5 writer configuration work.
- **Cold cache.** Every run is warm. Numbers are decode cost, not I/O cost.
