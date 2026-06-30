# What `carquet` Offers

## Scope

`qio` vendors `carquet` v0.6.0 at commit
`06efab6dce5475a7faa86f0938d42e9078b6d440`. It is a C11 library for reading,
writing, inspecting, and validating Apache Parquet files. The library is MIT
licensed and uses opaque handles for its main objects.

This document summarizes the complete vendored C API. It is not a description
of the smaller R API currently exposed by `qio`.

The public surface is defined by three headers:

- `src/carquet/carquet/carquet.h`: schemas, readers, writers, filtering,
  metadata, memory management, and extension points.
- `src/carquet/carquet/types.h`: physical types, logical types, encodings, and
  compression codecs.
- `src/carquet/carquet/error.h`: status codes and rich error information.

## Capabilities at a Glance

| Area | What the API offers |
|---|---|
| Data model | Every Parquet physical type, modern and legacy logical annotations, required/optional/repeated fields, and nested schemas |
| Reading | File-, `FILE*`-, and memory-backed readers; projected row batches; low-level column streams; parallel reads; dictionary-preserving reads |
| Writing | File-, `FILE*`-, and memory-backed writers; appending row groups; configurable pages, row groups, compression, encoding, statistics, and checksums |
| Pruning | Row-group statistics, bloom filters, column and offset indexes, and conservative page-level filters |
| Metadata | Schema and row-group inspection, footer key-value pairs, column-chunk details, sorting declarations, and geospatial statistics |
| Performance | Memory mapping, a narrow zero-copy path, I/O prebuffering, reusable thread pools, SIMD dispatch, and tunable batch/page sizes |
| Extensibility | Custom allocators and process-wide custom compression codecs |
| Diagnostics | Structured status codes, contextual error records, recovery hints, file validation, version information, and detected CPU features |

## Types and Schemas

The physical types are `BOOLEAN`, `INT32`, `INT64`, deprecated `INT96`,
`FLOAT`, `DOUBLE`, `BYTE_ARRAY`, and `FIXED_LEN_BYTE_ARRAY`. The C value buffer
must match the physical type; for example, booleans use one `uint8_t` per value,
variable binary values use `carquet_byte_array_t`, and fixed binary values are
tightly packed.

Logical annotations cover strings, integers, decimal values, dates, times,
timestamps, JSON, BSON, UUIDs, float16, lists, maps, variants, geometry,
geography, and interval data. The schema API can:

- add leaf columns and arbitrary groups;
- build standard three-level list and map layouts;
- build the standard unshredded variant layout;
- find columns by dotted path and inspect every schema node; and
- report maximum definition and repetition levels for each leaf.

Nested data remains close to Parquet's storage model. The API reads and writes
leaf columns plus definition and repetition levels; it does not materialize
nested row objects. `carquet_count_rows()` and `carquet_list_offsets()` help a
caller reconstruct repeated data.

## Reading

Choose the reader surface according to the job:

| Need | Main API |
|---|---|
| Scan rows, project columns, or read in parallel | `carquet_batch_reader_t` |
| Control one column in one row group or inspect level streams | `carquet_column_reader_t` |
| Inspect only basic footer information | `carquet_get_file_info()` and `carquet_validate_file()` |

Readers can open a path, a caller-owned `FILE*`, or a caller-owned memory
buffer. Once open, the API exposes the schema, row count, leaf-column count,
row-group count, row-group sizes, and detailed column metadata.

The batch reader is the default high-level interface. Its configuration
supports:

- projection by column index or name;
- configurable row batch size;
- automatic or explicit parallelism;
- row-group filter callbacks;
- an optional reusable thread pool; and
- preserving dictionary indices and dictionaries instead of materializing
  repeated values.

The low-level column reader streams physical values and optional definition and
repetition levels. It can also skip values and report whether values remain.
Nested structures are returned as physical leaf streams and must be rebuilt by
the caller.

## Writing

A writer copies its schema at creation, so the caller may free the schema after
creating the writer. Output can target a path, a caller-owned `FILE*`, or an
internal memory buffer. An existing file can also be opened to append new row
groups after its schema is validated.

Global writer options control:

- compression codec and level;
- target row-group, page, and internal write-batch sizes;
- maximum rows per page and dictionary-page size;
- statistics, page checksums, page indexes, and bloom filters;
- Arrow schema footer metadata;
- data-page and file-metadata versions; and
- timestamp coercion and truncation policy.

Before writing data, individual columns can override their encoding,
compression, page size, statistics, and bloom-filter settings. The writer can
also record key-value metadata and declared sorting columns. A sorting
declaration is metadata only: `carquet` does not sort or verify the input.

Writing is column-oriented. Every column must advance by the same number of
logical rows before starting a new row group or closing the writer. For a
nullable column, `num_values` and the definition-level array describe logical
rows, while the value buffer contains only present values packed contiguously.
Call `carquet_writer_abort()` after a failed write when close has not succeeded.

## Compression and Encoding

The vendored release has built-in implementations for Snappy, Gzip, LZ4,
LZ4 Raw, and Zstandard, plus uncompressed data. The codec enum also contains
LZO and Brotli slots; these require a registered custom codec. A custom codec
may also replace a built-in implementation and must be registered before
concurrent reader or writer activity begins.

The writer supports plain and dictionary encoding, byte-stream split for
suitable fixed-width values, delta binary packing for integers, and delta
length/delta byte-array encodings. Dictionary encoding can fall back to plain
encoding when the dictionary becomes too large or offers little benefit.

## Statistics, Indexes, and Filtering

`carquet` exposes Parquet's pruning structures instead of hiding them:

| Structure | Use |
|---|---|
| Row-group statistics | Inspect min/max/null counts and conservatively skip row groups |
| Bloom filter | Test whether a column chunk definitely lacks a value or might contain it |
| Column index | Read per-page min/max/null statistics |
| Offset index | Read page offsets, compressed sizes, and first-row positions |
| Page filter | Skip pages using `EQ`, `NE`, ordering, range, set-membership, and null predicates |

Page filters are conjunctive and conservative. They avoid decoding pages that
cannot match, but they do not remove non-matching rows inside pages that remain;
the caller must apply the exact row predicate. Predicate columns do not need to
be projected, but they must have page indexes.

The metadata API also exposes footer key-value entries, encodings and
compression used by each column chunk, optional-index availability, and
bounding boxes and geometry-type codes for geospatial columns.

## Performance and Concurrency

The main performance controls are projection, batch size, threading, memory
mapping, and file layout. Memory mapping enables a zero-copy path only for
required, uncompressed, plain-encoded, fixed-width columns. On non-mapped or
high-latency storage, `carquet_reader_prebuffer()` can coalesce reads for
several columns in one row group.

Dictionary-preserving batch reads avoid materializing repeated strings and can
be useful for dictionary-heavy columns. Writer-side statistics, page indexes,
and bloom filters trade additional work and file space for cheaper future
reads.

Initialization is automatic and thread-safe. Multiple independent readers may
operate concurrently, and multiple column readers may read concurrently from a
reader. A single column reader, batch reader, or writer must not be used from
multiple threads without external synchronization. Custom allocator changes
and codec registration are process-wide setup operations, not concurrent
runtime operations.

The library detects SIMD features at runtime. In `qio`, the current build
enables NEON on ARM64 and otherwise uses the portable scalar path; x86-specific
SIMD compilation is intentionally not enabled by the package Makevars.

## Errors and Ownership

Fallible operations return `carquet_status_t`, a nullable handle, or a negative
count, depending on the API family. `carquet_error_t` adds a message, source
location, file offset, row-group index, and column index. Helper functions
provide status names, formatted messages, recovery hints, and a recoverability
classification.

Important ownership rules are:

- a schema returned by `carquet_reader_schema()` belongs to the reader;
- a buffer passed to `carquet_reader_open_buffer()` belongs to the caller and
  must remain unchanged until the reader closes;
- batch data, null bitmaps, and dictionaries belong to the batch reader and
  must not be retained across the next batch;
- bloom filters, column indexes, and offset indexes have explicit destroy/free
  functions;
- a caller-owned `FILE*` remains the caller's responsibility; and
- memory-buffer output follows `create_buffer()` → `close()` → `get_buffer()`;
  `get_buffer()` transfers the bytes to the caller, which frees them with
  `free()`.

## Current `qio` Binding Boundary

The vendored library is considerably broader than `qio`'s current public R
interface. `src/qio.c` uses the schema builder, path-based reader and writer,
and low-level column readers to implement flat data-frame round trips.

Currently exposed R mappings are:

| R | Parquet write type | Parquet read type |
|---|---|---|
| logical | `BOOLEAN` | logical |
| integer | `INT32` | integer |
| double | `DOUBLE` | double |
| character/factor | `BYTE_ARRAY` with `STRING` annotation | character |
| — | — | `INT64` and `FLOAT` become double |

The R binding does not currently expose nested schemas, logical date/time
annotations, batch projection, predicate pushdown, metadata inspection,
in-memory I/O, append mode, dictionary preservation, or writer tuning beyond
compression selection. Those are capabilities available in the vendor API for
possible future bindings.

## Source Map

| Area | Header | Key symbols |
|---|---|---|
| Types | `src/carquet/carquet/types.h` | `carquet_physical_type_t`, `carquet_logical_type_t`, `carquet_encoding_t`, `carquet_compression_t` |
| Errors | `src/carquet/carquet/error.h` | `carquet_status_t`, `carquet_error_t`, `carquet_error_format()` |
| Schemas | `src/carquet/carquet/carquet.h` | `carquet_schema_*`, `carquet_count_rows()`, `carquet_list_offsets()` |
| Reading | `src/carquet/carquet/carquet.h` | `carquet_reader_*`, `carquet_column_*`, `carquet_batch_reader_*`, `carquet_row_batch_*` |
| Writing | `src/carquet/carquet/carquet.h` | `carquet_writer_*` |
| Pruning and metadata | `src/carquet/carquet/carquet.h` | statistics, bloom-filter, index, page-filter, and metadata APIs |
| R bridge | `src/qio.c` | `qio_read_parquet()`, `qio_write_parquet()` |

## References

- [`carquet` manual](https://github.com/Vitruves/carquet/tree/main/docs)
- [Reading files](https://github.com/Vitruves/carquet/blob/main/docs/reading.md)
- [Writing files](https://github.com/Vitruves/carquet/blob/main/docs/writing.md)
- [Nested and nullable data](https://github.com/Vitruves/carquet/blob/main/docs/nested-data.md)
- [Performance and tuning](https://github.com/Vitruves/carquet/blob/main/docs/performance.md)
- [Error handling and types](https://github.com/Vitruves/carquet/blob/main/docs/error-handling.md)
- [Apache Parquet documentation](https://parquet.apache.org/docs/)
