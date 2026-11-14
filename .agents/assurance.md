# Assurance

How this package meets `.claude/shared/assurance.md`. CI checks this
file (r-actions `assurance.yml`), so keep the headings and table
columns as they are.

- **Statuses:** a cell is a fact, `gap #<issue>` or `n/a: <reason>`.
- **Written:** 2026-11-13 against `d409cc2`, from the tests and the C,
  not from the design documents. Scripts under `tools/` that no workflow
  calls are by hand, and do not count as a check here.
- **Gaps are grouped.** The first pass found about 50 gap rows. Filing one
  issue per row would bury the work in near-duplicates, because most rows
  close with the same oracle: one pyarrow reference set closes eleven decode
  rows. So each gap names the issue for the oracle or check that closes it,
  and several rows share an issue. Split a row out of its group when it is
  worked on separately.

## Kinds

`compiled` `untrusted-input` `spec` `lifecycle` `emits`

## Required checks

`Where` names the workflow file under `.github/workflows/` that runs the
check. Add `(own)` when that workflow is the package's own rather than a
call to r-actions.

| Check         | Status | Where             |
| ------------- | ------ | ----------------- |
| sanitizers    | done   | native-checks.yml |
| valgrind      | done   | native-checks.yml |
| rchk          | done   | native-checks.yml |
| gctorture     | done   | gctorture.yml     |
| analyzers     | gap #52 |                   |
| alloc-failure | gap #53 |                   |
| mutation      | gap #54 |                   |
| fuzz          | gap #55 |                   |
| fuzz-reach    | gap #55 |                   |

## Boundaries

One row per boundary the package crosses. An oracle knows the answer:

- a conformance suite or test vectors;
- a reference implementation;
- a round trip;
- equivalent inputs compared;
- the bytes the other side received.

"No crash" is not an oracle.

<!-- markdownlint-disable MD013 -->
| Boundary | Oracle | Carried by |
| --- | --- | --- |
| Parquet footer (Thrift) decode | parquet-testing corpus at a pinned commit, and Arrow-written fixtures with known values | tests/testthat/test-external.R |
| Parquet footer (Thrift) decode | footer fields (sizes, offsets, codecs, encodings) compared with pyarrow's metadata | gap #56 |
| Parquet file encode | arrow and nanoparquet read qio-written files and must agree with qio | bench/compare-readers.R (benchmark.yml, compare-readers) |
| Parquet file encode | Arrow's read of every qio-written type compared with the input frame, all codecs | gap #57 |
| PLAIN decode, all non-INT96 physical types | Arrow-written fixture against an RDS built in base R from the generator's input | tests/testthat/test-external.R |
| INT96 decode | every row compared with pyarrow (only one value is asserted now) | gap #56 |
| DECIMAL decode (INT32, INT64, FLBA, BYTE_ARRAY) | Arrow fixtures with known values; byte-pattern unit tests | tests/testthat/test-external.R |
| DECIMAL decode (INT32, INT64, FLBA, BYTE_ARRAY) | parquet-testing decimal files, and precision above 17 | gap #56 |
| Temporal decode (DATE, TIME, TIMESTAMP units, UTC and local, DST) | RDS references derived from the generators' input | tests/testthat/test-external.R |
| Integer annotations, INT64/UINT64 bounds, INT32 sentinel | Arrow fixtures with values chosen at the bounds | tests/testthat/test-external.R |
| UUID decode | fixture written by an independent writer (now carquet-written) | gap #56 |
| FLOAT16 decode | all 65536 bit patterns against numpy's float16 widening | gap #56 |
| STRING, JSON, binary decode | Arrow fixtures with known values | tests/testthat/test-external.R |
| ENUM decode | fixture from parquet-java | gap #56 |
| Dictionary decode, including fallback and nulls | Arrow fixtures with whole-column expectations; path counters assert the branch | tests/testthat/test-external.R |
| DELTA_BINARY_PACKED decode | pyarrow fixture with exact sequences | tests/testthat/test-external.R |
| DELTA_BINARY_PACKED decode | random and extreme deltas, ragged last miniblock, against pyarrow | gap #56 |
| DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY decode | whole columns against pyarrow (two values of 300 are asserted now) | gap #56 |
| BYTE_STREAM_SPLIT decode | pyarrow fixture, FLOAT and DOUBLE in full | tests/testthat/test-external.R |
| RLE/bit-packed hybrid levels, RLE BOOLEAN, DATA_PAGE_V2 | pyarrow fixture recomputed from the generator's pattern; corpus file | tests/testthat/test-external.R |
| Snappy, gzip, zstd, LZ4_RAW decode | pyarrow fixture, one codec per column, known values | tests/testthat/test-external.R |
| Legacy LZ4 (Hadoop framing) decode | parquet-testing hadoop_lz4 files and their documented values | gap #56 |
| Codec and encoding encode | round trip and `column_chunks()` encodings; Arrow against the input by hand only | gap #57 |
| BINARY write (list of raw) | qio round trip only; Arrow's read compared with the input | gap #57 |
| Column statistics decode | Arrow fixture with exact bounds; pyarrow statistics dump per fixture | gap #56 |
| Column statistics encode | bounds computed from the input, read back by qio | tests/testthat/test-inspect.R |
| Column statistics encode | pyarrow reads the same min, max and null count from qio files | gap #57 |
| Page index decode | pyarrow fixture; every page's bounds derivable from the key | gap #56 |
| Bloom filter probe | pyarrow fixture: no false negatives, false-positive rate in bulk | tests/testthat/test-inspect.R |
| `sorted_by` encode | pyarrow's `sorting_columns` from a qio file | gap #57 |
| Footer key/value metadata | qio round trip with duplicates, NA, non-ASCII | tests/testthat/test-inspect.R |
| Footer key/value metadata | pyarrow in both directions, invalid UTF-8 and embedded NUL | gap #56 |
| GEOMETRY/GEOGRAPHY logical type decode (CRS, algorithm) | parquet-testing geospatial fixtures, CRS reported whole at 2,320 bytes | tests/testthat/test-external.R |
| GEOMETRY/GEOGRAPHY logical type encode (CRS, algorithm) | DuckDB's `parquet_schema()` reads the CRS from a qio file | tests/testthat/test-ci-geospatial-oracle.R (oracles.yml) |
| GeospatialStatistics decode | a third-party file carrying statistics, against pyarrow's `geo_statistics` | gap #58 |
| GeospatialStatistics encode | hand-derived bounds, read back through carquet's own decoder | tests/testthat/test-parquet-file.R |
| GeospatialStatistics encode | DuckDB's `parquet_metadata()` reads qio's box and types, with spec-derived expectations: repeated values, multis, NaN, non-WKB, GEOGRAPHY | tests/testthat/test-ci-geospatial-oracle.R (oracles.yml) |
| GeospatialStatistics encode | the same WKB written by pyarrow and qio compared | gap #58 |
| Append | read back equals `rbind()` of the inputs | tests/testthat/test-append.R |
| URL read | `file://` read equals the local read | tests/testthat/test-url.R |
| URL read | HTTP from a loopback server equals the local read | gap #62 |
| UTF-8 validation of data values | invalid-UTF-8 fixture; byte-by-byte differential by hand | gap #62 |
| Nested column skip | Arrow fixture and corpus files; absence asserted | tests/testthat/test-external.R |
<!-- markdownlint-enable MD013 -->

## Objects

One row per object that outlives the call that made it. "Sequences" is
the test of its out-of-order use (abort then read, use after end, use
after free). The guard columns name the test, or say why the guard
cannot apply.

<!-- markdownlint-disable MD013 -->
| Object | Sequences | Fork | Unwind | Owner |
| --- | --- | --- | --- | --- |
| open handle, buffered | tests/testthat/test-parquet-file.R (double close, use after close, collect and close inside a callback); model-based sequences gap #59 | gap #45 | gap #53 | tests/testthat/test-parquet-file.R |
| open handle, mmap | tests/testthat/test-parquet-file.R; the file truncated under the mapping gap #59 | gap #59 | gap #53 | tests/testthat/test-parquet-file.R |
| downloaded temporary copy | tests/testthat/test-url.R | gap #59 | tests/testthat/test-url.R | gap #59 |
| writer, new file | tests/testthat/test-qio.R (error mid-write leaves no file); interrupt gap #60 | n/a: lives only for the call and runs no R code while it holds the file | tests/testthat/test-qio.R | tests/testthat/test-qio.R |
| writer, append | tests/testthat/test-append.R (refusals; a native failure after a flushed row group restores the file); interrupt gap #60 | n/a: lives only for the call | tests/testthat/test-append.R | tests/testthat/test-append.R |
| collect worker pool and private readers | tests/testthat/test-parquet-file.R; error while tasks run gap #59 | n/a: runs no R code while the pool exists | gap #60 | tests/testthat/test-parquet-file.R |
| walk_batches batch reader and pool | tests/testthat/test-parquet-file.R (callback error, then reuse) | gap #45 | tests/testthat/test-parquet-file.R | tests/testthat/test-parquet-file.R |
<!-- markdownlint-enable MD013 -->

## Limits

One row per limit the package enforces. "Straddled by" is the test of
`limit - 1`, `limit` and `limit + 1` on every path that reaches it.

<!-- markdownlint-disable MD013 -->
| Limit | Unit | Straddled by |
| --- | --- | --- |
| `batch_size` in [1, INT_MAX] | rows | gap #61 |
| `threads`, no upper cap | threads | gap #61 |
| `row_group_size` at least 1 | rows | gap #61 |
| rows written at most INT_MAX | rows | gap #61 |
| binary value at most 2^31 - 1 | bytes | gap #61 |
| explicit INT64 input in [-2^53, 2^53] | value | gap #61 |
| INT64 and UINT64 exact read range | value | tests/testthat/test-external.R |
| explicit INT32 input in [-2^31 + 1, 2^31 - 1] | value | tests/testthat/test-parquet-schema.R |
| DATE input in days | days | gap #61 |
| TIMESTAMP scaled value in (-2^63, 2^63) | declared unit | gap #61 |
| INT32 INT_MIN read as NA | value | tests/testthat/test-external.R |
| CRS on write at most 127 | UTF-8 bytes | gap #61 |
| CRS on read, inline 127 then held whole | bytes | gap #58 |
| `QIO_WRITE_CHUNK` 65536 | rows | gap #61 |
| `QIO_TASK_BATCH` 65536 | rows | gap #61 |
| `QIO_PRIVATE_READER_MIN_ROWS` 50000 | rows | gap #61 |
| `CARQUET_POOL_QUEUE_CAPACITY` 512 | tasks | gap #61 |
| character cache 512 entries, 4096-lookup trial | entries | gap #61 |
| carquet `max_statistics_size` 32 | bytes | gap #61 |
| `CARQUET_MAX_GEOSPATIAL_TYPES` 64 | items | gap #55 |
<!-- markdownlint-enable MD013 -->
