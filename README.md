# qio

`qio` reads and writes Apache Parquet files from R, through the bundled C
library [`carquet`](https://github.com/Vitruves/carquet). It has no required
runtime R dependencies; two optional result types use suggested packages.

## Installation

qio is not on CRAN yet. Install the development version from GitHub:

```r
pak::pak("pedrobtz/qio")
```

Building from source needs GNU make and a C compiler. Zstandard and LZ4 are
bundled; zlib comes from the system, or from Rtools on Windows.

## Examples

Write and read a data frame:

```r
qio::write_parquet(mtcars, "mtcars.parquet")
cars <- qio::read_parquet("mtcars.parquet")
```

Override an inferred writer type:

```r
types <- qio::parquet_schema(mpg = "FLOAT", cyl = "INT64")
qio::write_parquet(mtcars, "mtcars.parquet", schema = types)
```

Write something other tools can prune, with provenance in the footer:

```r
qio::write_parquet(
  mtcars,
  "mtcars.parquet",
  row_group_size = 8,
  metadata = c(source = "mtcars")
)
```

Open a file for inspection and selective reading:

`schema()`, `row_groups()`, and `collect()` are S3 generics, so this block
attaches the package rather than qualifying every call:

```r
library(qio)

pf <- open_parquet("mtcars.parquet")
pf
#> <qio_parquet_file>
#> /path/to/mtcars.parquet
#> 32 rows x 11 columns; 4 row groups

dim(pf)                  # c(32L, 11L)
schema(pf)               # column types and physical encodings
row_groups(pf)           # row counts and sizes
column_statistics(pf)    # per-group bounds and null counts

df <- collect(pf, columns = c("mpg", "cyl"))
close_parquet(pf)
```

`collect()` also works when dplyr is attached and masks it: qio registers its
method on dplyr's generic too, so `collect(pf)` and `dplyr::collect(pf)` both
read the file.

Read a large file in batches, without holding it all in memory:

```r
pf <- qio::open_parquet("big.parquet")
qio::walk_batches(pf, function(batch, index) {
  # one data frame at a time
}, batch_size = 100000)
qio::close_parquet(pf)
```

## What qio supports

Everything below is exercised against files written by other implementations,
not only by round-tripping qio's own output. Each fixture's provenance is in
`tests/testthat/parquet/SOURCE.md`.

### Reading

| Area | Supported |
|---|---|
| Physical types | `BOOLEAN`, `INT32`, `INT64`, `INT96`, `FLOAT`, `DOUBLE`, `BYTE_ARRAY`, `FIXED_LEN_BYTE_ARRAY` |
| Text | `STRING`, `ENUM`, `JSON` as character, validated as UTF-8 |
| Binary | Unannotated `BYTE_ARRAY` and `FIXED_LEN_BYTE_ARRAY` as lists of raw vectors |
| Temporal | `DATE`, UTC and non-UTC `TIMESTAMP`, `TIME`, legacy `INT96` |
| Numeric | `INTEGER` at every width and signedness, `DECIMAL`, `FLOAT16`, `UUID`, `NULL` |
| Encodings | `PLAIN`, `PLAIN_DICTIONARY`, `RLE_DICTIONARY`, `RLE`, `BIT_PACKED`, all three `DELTA_*`, `BYTE_STREAM_SPLIT` |
| Compression | Uncompressed, Snappy, Zstandard, Gzip, LZ4 |
| Page versions | V1 and V2 |
| Parallelism | Column-parallel decode on both mapped and buffered handles |

`?qio-types` is the complete table: every physical type, the logical
annotations qio applies to it, the R type it produces, where precision is lost,
and whether it can be written. `read_plan()` answers the same question for one
real file before reading it.

Column selection resolves by complete schema path, so two leaves sharing a name
under different parents stay distinct.

### Writing

| Area | Supported |
|---|---|
| R types | logical, integer, double, character, factor, `Date`, `POSIXct` |
| Type overrides | `INT64`, `FLOAT`, and timestamp unit, via `parquet_schema()` |
| Compression | Snappy (default), Zstandard, Gzip, LZ4, uncompressed |
| Layout | Row groups by row count |
| Metadata | Footer key/value pairs; a declared sort order |
| Append | New row groups on an existing file, after a full schema check |

### Inspecting

| Function | Reports |
|---|---|
| `schema()` | Leaf paths, physical and logical types, repetition, levels |
| `read_plan()` | The R type each column will become, before reading |
| `row_groups()` | Row counts and compressed and uncompressed sizes |
| `column_chunks()` | Per-chunk type, codec, sizes, encodings, optional structures |
| `column_statistics()` | Per-chunk value and null counts, minimum and maximum |
| `page_index()` | Per-page bounds, null counts, offsets, and starting rows |
| `bloom_filter_may_contain()` | Whether a value is definitely absent from a chunk |
| `metadata()` | Footer key/value pairs, duplicates and order preserved |
| `validate_parquet()` | Whether a file is structurally valid, and what is wrong |

Statistics, bounds, and declared sort orders are claims made by whoever wrote
the file. qio reports them and does not act on them.

### Not supported

| Area | Status |
|---|---|
| Nested columns (`LIST`, `MAP`, struct) | Skipped on read with a message; deferred to 0.2.0 |
| Predicate pushdown and page filtering | Out of scope for 0.1.0; filter in R after reading |
| Writing bloom filters and page indexes | Readable, not writable |
| Exact decimal arithmetic | `DECIMAL` reads as `double` with its scale applied |
| Non-UTC timestamp writes | `POSIXct` writes as UTC-adjusted; deferred to 0.2.0 |
| Encrypted footers | Rejected with a clear message |

`?qio-limitations` records each of these with its reason.

Two limits come from R rather than from Parquet: a single result cannot exceed
`.Machine$integer.max` rows, and `INT64` loses precision beyond 2^53 unless read
with `int64 = "integer64"`.

## Performance

The repository's `bench/` directory holds a reproducible benchmark over fixed
workloads. It is excluded from the source package, so run it from a checkout:

```sh
Rscript bench/benchmark.R                    # run and print
Rscript bench/benchmark.R --compare <tag>    # compare against a saved baseline
```

Figures recorded during development are in `bench/README.md`. They come from one
machine and one build configuration, and exist to make regressions visible
between commits -- not to predict what any other machine will do. Measure on
your own hardware before relying on a number.

## Licensing

qio is MIT licensed. It bundles third-party C sources, each under its own
license and shipped with its license file:

| Bundled | License | Location |
|---|---|---|
| carquet | MIT | `src/carquet/LICENSE` |
| Zstandard | BSD-3-Clause | `src/zstd/LICENSE` |
| LZ4 | BSD-2-Clause | `src/lz4/LICENSE` |

Each is pinned to an exact upstream commit. qio carries local patches to
carquet; most fix defects that silently corrupted or rejected valid data. The
pins, the patches, and the reason for each are recorded in the repository's
`.agents/VENDORED.md`, which is not shipped in the source package.

## References

- [Apache Parquet](https://parquet.apache.org/docs/)
- [Parquet encodings](https://parquet.apache.org/docs/file-format/data-pages/encodings/)
- [`carquet`](https://github.com/Vitruves/carquet)
