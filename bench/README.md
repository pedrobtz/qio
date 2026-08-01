# qio benchmarks

Reproducible read and write benchmarks, and the recorded v0.1.0 baseline.
`bench/` is excluded from the source package by `.Rbuildignore`; nothing here
ships, and no test loads anything from this directory.

Ordered work and exit gates live in [`../.agents/plan.md`](../.agents/plan.md).
This file owns the benchmark method, the reference workloads, and the
regression threshold.

## Commands

```sh
Rscript bench/benchmark.R                          # run all, print a table
Rscript bench/benchmark.R --save baseline          # also save results/<tag>.csv
Rscript bench/benchmark.R --compare baseline       # compare with a saved run
Rscript bench/benchmark.R --reps 20 --filter read- # subset, more repetitions
```

`--compare` exits non-zero if any case regresses past the threshold, so it can
gate a change without a human reading the table.

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

1. qio's writer flushes a row group only when carquet's byte target is exceeded
   (128MB default), so a qio-written fixture of this size is a *single* row
   group. Benchmarking against that would exercise none of the multi-row-group
   paths phase 4 changes — parallel collect schedules one task per row group
   per column, and row-group projection would be a no-op.
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

## Baseline

Recorded on the commit that completed phase P, before any phase 4 work.

- R 4.6.1, `aarch64-apple-darwin23`, Darwin/arm64, 8 cores
- 10 repetitions, 2 warmups
- Saved to `bench/results/baseline.csv` (not committed; regenerate with
  `--save baseline`)

| Case | Median (s) | Min (s) | IQR (s) |
|---|---|---|---|
| `read-numeric` | 0.1170 | 0.107 | 0.0073 |
| `read-numeric_nulls` | 0.1250 | 0.113 | 0.0330 |
| `read-string_low_cardinality` | 0.1220 | 0.121 | 0.0060 |
| `read-string_high_cardinality` | 0.2840 | 0.280 | 0.0065 |
| `read-mixed` | 0.0970 | 0.086 | 0.0133 |
| `collect-buffered` | 0.2660 | 0.264 | 0.0008 |
| `collect-mmap` | 0.0980 | 0.069 | 0.0415 |
| `collect-mmap-serial` | 0.2650 | 0.264 | 0.0018 |
| `collect-projection` | 0.0780 | 0.078 | 0.0010 |
| `collect-row-groups` | 0.0670 | 0.067 | 0.0007 |
| `walk-batches` | 0.3630 | 0.360 | 0.0103 |
| `write-numeric` | 0.4060 | 0.393 | 0.0360 |
| `write-string_low_cardinality` | 0.3015 | 0.295 | 0.0153 |
| `write-mixed` | 0.4535 | 0.447 | 0.0042 |

### What the baseline already shows

Two results are worth carrying into phase 4 rather than rediscovering:

- **The speedup is parallelism, not mmap.** `collect-mmap-serial` (0.265) is
  indistinguishable from `collect-buffered` (0.266), while `collect-mmap`
  (0.098) is 2.7x faster than both. Mapping alone buys nothing here; the worker
  pool buys everything. Phase 4 asks whether private-reader parallelism for
  buffered reads is justified — on this evidence it is worth about 2.7x for
  every persistent handle, since `parquet_open()` defaults to `mmap = FALSE`.
- **`walk_batches()` is the slowest way to read the same file.** 0.363 against
  0.266 for `collect-buffered`, so the batch reader costs roughly 35% more than
  the direct column path for a full pass.

Neither is a defect; both are starting points with numbers attached.

## Not measured yet

- **Peak memory.** The phase 4 gate on bounded string scratch needs a peak-RSS
  probe; wall time will not show it. `read-string_high_cardinality` is the
  workload it should run against, and the instrument still has to be chosen.
- **Compression codecs.** Everything here is Snappy, qio's default. Codec
  comparisons belong with the phase 5 writer configuration work.
- **Cold cache.** Every run is warm. Numbers are decode cost, not I/O cost.
