# How `carquet` Works in `qio`

## Scope and Status

`qio` vendors `carquet` v0.6.0 from commit
`06efab6dce5475a7faa86f0938d42e9078b6d440`, with the qio-local patches recorded
in `.agents/VENDORED.md`. It is a C11 library for reading, writing, inspecting,
and validating Apache Parquet files. The library is MIT licensed and uses opaque
handles for its main objects.

This document describes the vendored snapshot, including implementation
constraints that are not obvious from the public headers, and then identifies
the smaller surface currently exposed by `qio`. The vendored source and local
patch ledger are authoritative; the pinned upstream commit lacks the local
patches, while upstream `main` may describe a later release.

The public API is defined by three headers:

- `src/carquet/carquet/carquet.h`: schemas, readers, writers, filtering,
  metadata, memory management, and extension points.
- `src/carquet/carquet/types.h`: physical types, logical types, encodings, and
  compression codecs.
- `src/carquet/carquet/error.h`: status codes and rich error information.

## Mental Model

A Parquet file is organized as follows:

```text
file
|-- schema tree
|-- row group 0
|   |-- leaf column chunk 0
|   |   `-- encoded and compressed pages
|   `-- leaf column chunk N
|       `-- encoded and compressed pages
|-- row group N
`-- footer metadata
```

`carquet` works primarily with physical **leaf-column streams**, not nested row
objects. A leaf stream contains:

- dense physical values for entries that are present;
- definition levels that describe nullability; and
- repetition levels that describe repeated and nested structure.

The schema supplies the maximum definition and repetition levels needed to
interpret those streams. Reconstructing a list, map, or nullable struct requires
combining the schema, values, definition levels, and repetition levels.

### Reader flow

1. `carquet_reader_open*()` reads the footer and builds a reader-owned schema
   and row-group metadata.
2. A low-level column reader opens one leaf column in one row group.
3. It reads page headers, optionally verifies checksums, decompresses pages, and
   decodes values and levels.
4. A batch reader coordinates projected column readers, aligns their output to
   logical rows, builds validity bitmaps, and advances across row groups.
5. Optional row-group and page filters prune data conservatively; callers still
   apply the exact row predicate.

### Writer flow

1. A writer copies the supplied schema when it is created.
2. The caller writes columns using dense values plus definition and repetition
   levels.
3. Column writers encode and compress pages. Aligned columns are assembled into
   row groups.
4. Closing flushes the final row group and writes indexes, footer metadata, the
   footer length, and trailing Parquet magic.

## Capabilities at a Glance

| Area | Vendored capability and important constraint |
|---|---|
| Data model | All Parquet physical types, modern and legacy logical annotations, required/optional/repeated fields, and nested schemas; nested values remain leaf streams |
| Reading | Path-, caller-owned `FILE*`-, and caller-owned memory-backed readers; projected batches and low-level columns; parallel decode only on mmap or memory-backed input |
| Writing | Path-, caller-owned `FILE*`-, and memory-backed writers; append mode; configurable pages, row groups, compression, encoding, statistics, and checksums |
| Pruning | Row-group statistics, bloom filters, column and offset indexes, and conservative page-level filters |
| Metadata | Schema and row-group inspection, footer key-value pairs, column-chunk details, sorting declarations, and geospatial statistics |
| Performance | Memory mapping, a narrow zero-copy path, I/O prebuffering, reusable thread pools, SIMD dispatch, and tunable batch/page sizes |
| Extensibility | Custom allocators and process-wide custom compression codecs |
| Diagnostics | Structured status codes, contextual errors, recovery hints, validation, version information, and detected CPU features |

## Types, Schemas, and Nested Data

The physical types are `BOOLEAN`, `INT32`, `INT64`, deprecated `INT96`,
`FLOAT`, `DOUBLE`, `BYTE_ARRAY`, and `FIXED_LEN_BYTE_ARRAY`. The value buffer
must match the physical type. For example, booleans use one `uint8_t` per value,
variable binary values use `carquet_byte_array_t`, and fixed binary values are
tightly packed.

Logical annotations include strings, integers, decimals, dates, times,
timestamps, JSON, BSON, UUIDs, float16, lists, maps, variants, geometry,
geography, and legacy interval annotations. The schema API can:

- add leaf columns and arbitrary groups;
- build standard three-level list and map layouts;
- build the standard unshredded variant layout;
- inspect every schema node and return a leaf's path components; and
- report maximum definition and repetition levels for each leaf.

There are important limitations:

- `carquet_schema_find_column()` searches the **leaf name only**. It does not
  parse dotted paths, despite the public header comment. Duplicate leaf names
  in separate nested branches are ambiguous; use leaf indexes and
  `carquet_schema_column_path()` when paths matter.
- `carquet_count_rows()` counts repetition-level-zero entries.
- `carquet_list_offsets()` derives offsets from repetition levels only. Neither
  helper uses definition levels, so neither can by itself distinguish null and
  empty lists, null elements, or nullable structs.
- The list and map builder helpers create the standard layouts with their own
  element/key/value repetition choices. Use the lower-level schema builder for
  other legal nullability shapes.

## Reading

### Reader surfaces

| Need | Main API |
|---|---|
| Scan aligned rows or project several columns | `carquet_batch_reader_t` |
| Read one leaf in one row group or inspect level streams | `carquet_column_reader_t` |
| Inspect basic footer information or validate a file | `carquet_get_file_info()` and `carquet_validate_file()` |

Readers can open a path, a caller-owned `FILE*`, or a caller-owned memory
buffer. Once open, the API exposes the schema, row count, leaf-column count,
row-group count, row-group sizes, footer metadata, and column-chunk metadata.

Memory mapping is a reader-open option. The `use_mmap` member in
`carquet_batch_reader_config_t` is initialized but not consulted by the
vendored batch implementation; configuring it there does not map an already
open reader.

### Low-level column reader

The low-level reader returns dense physical values and, when requested,
definition and repetition levels. It can skip logical values and report how
many remain. The caller is responsible for scattering dense values into rows
and reconstructing nested structures.

For `BYTE_ARRAY`, returned `carquet_byte_array_t.data` pointers may refer to
mapped input or retained page buffers owned by the reader. Treat them as
borrowed batch data: consume or copy the bytes before another operation that
can reposition the column reader, and never retain them after closing the
column or file reader.

### Batch reader

The batch reader supports:

- projection by leaf index or leaf name;
- configurable row batch size;
- row-group filter callbacks;
- optional page filters;
- automatic or explicit parallelism;
- an optional reusable thread pool; and
- dictionary-preserving output.

Name projection inherits the leaf-name lookup limitation. Prefer indexes for
nested schemas or schemas with duplicate leaf names.

Dictionary preservation is selected before the first page from the presence of
a dictionary page. It succeeds only when the chunk remains dictionary encoded.
If a chunk later falls back to `PLAIN`, the read fails with
`CARQUET_ERROR_INVALID_ENCODING`; it does not automatically retry with
materialized values. Dictionary and index buffers belong to the batch reader
and are valid only for the current batch.

## Writing

A writer copies its schema at creation, so the caller may free the schema after
creating the writer. Output can target a path, a caller-owned `FILE*`, or an
internal memory buffer.

Global writer options control:

- compression codec and level;
- target row-group, page, and internal write-batch sizes;
- maximum rows per page and dictionary-page size;
- statistics, page checksums, page indexes, and bloom filters;
- Arrow schema footer metadata;
- data-page and file-metadata versions; and
- timestamp coercion and truncation policy.

Individual columns can override encoding, compression, page size, statistics,
and bloom-filter settings. The writer can also add footer key-value metadata and
declare sorting columns. A sorting declaration is metadata only: `carquet` does
not sort or verify the input.

Writing is column-oriented. Every column must advance by the same number of
logical rows before beginning a new row group or closing the writer. For a
nullable column, `num_values` and definition levels describe logical entries,
while the value buffer contains only present values packed contiguously.

### Defaults and encoding

The v0.6.0 implementation initializes the writer with:

- uncompressed output;
- `PLAIN` encoding for most columns; and
- automatic `BYTE_STREAM_SPLIT` for `FLOAT` and `DOUBLE` when compression is
  enabled.

Dictionary encoding is opt-in through
`carquet_writer_set_column_encoding()`. The global `dictionary_encoding` option
is initialized but is not used by the implementation's default encoding
policy. Dictionary encoding can fall back to `PLAIN` when the dictionary
becomes too large or is not useful.

The writer also supports delta binary packing for integers and delta length or
delta byte-array encodings. A requested legacy `LZ4` codec is written as
`LZ4_RAW`, matching the raw blocks produced by the implementation.

### Append validation

Append mode preserves existing row groups and writes a new footer containing
the old and new row groups. Before appending, it compares leaf count and order,
leaf names, physical types, repetition, fixed-length widths, and logical-type
IDs.

This is not full schema equivalence. It does not compare the complete parent
group/path structure or logical parameters such as decimal precision and scale,
timestamp unit and UTC flag, integer width and signedness, or geospatial CRS.
Callers requiring strict compatibility must validate those separately.

### Writer lifecycle

For path and `FILE*` writers:

```text
create -> configure -> write -> close
                         `-> abort on failure before close
```

`carquet_writer_close()` invalidates and frees a non-buffer writer even when it
returns an error. Do not call `carquet_writer_abort()` after `close()` returns.
Abort after a failed write or row-group operation, before attempting close.

For memory-buffer output:

```text
create_buffer -> write -> close -> get_buffer
                    `-> abort on failure
```

The buffer-writer handle remains alive after close so
`carquet_writer_get_buffer()` can transfer the bytes and free the handle.

## Compression

The vendored release includes Snappy, Gzip, LZ4, LZ4 Raw, and Zstandard, plus
uncompressed data. The codec enum also contains LZO and Brotli slots; those
require a registered custom codec. A custom codec may replace a built-in
implementation and must be registered before concurrent reader or writer work
begins.

## Statistics, Indexes, and Filtering

`carquet` exposes Parquet's pruning structures directly:

| Structure | Use |
|---|---|
| Row-group statistics | Inspect min/max/null counts and conservatively skip row groups |
| Bloom filter | Determine that a chunk definitely lacks a value or may contain it |
| Column index | Read per-page min/max/null statistics |
| Offset index | Read page offsets, compressed sizes, and first-row positions |
| Page filter | Skip pages using equality, ordering, range, set-membership, and null predicates |

Page filters are conjunctive and conservative. They avoid decoding pages that
cannot match, but do not remove non-matching rows from pages that remain. The
caller must apply the exact row predicate. Predicate columns need not be
projected, but they must have page indexes. `INT96` predicates are unsupported
because Parquet does not define their sort order.

The metadata API also exposes footer key-value entries, encodings and
compression used by each chunk, optional-index availability, and bounding boxes
and geometry-type codes for geospatial columns. External column metadata files
are not implemented in this snapshot.

## Performance and Concurrency

The principal performance controls are projection, batch size, threading,
memory mapping, and file layout.

Memory mapping enables zero-copy reads only for required, non-repeated,
uncompressed, `PLAIN`-encoded fixed-width columns: `INT32`, `INT64`, `INT96`,
`FLOAT`, `DOUBLE`, and `FIXED_LEN_BYTE_ARRAY`. `BOOLEAN` and `BYTE_ARRAY` are
excluded. On buffered or high-latency storage,
`carquet_reader_prebuffer()` can coalesce selected column-chunk ranges for one
row group.

Concurrency rules are:

- independent reader handles may operate concurrently;
- multiple column readers sharing an mmap- or memory-backed reader may decode
  concurrently;
- multiple column readers sharing the buffered `FILE*` path must not read
  concurrently because they share mutable `fseek()`/`fread()` and prebuffer
  state; and
- a single column reader, batch reader, or writer must not be called
  concurrently without external synchronization.

The batch reader only parallelizes page work when its reader has mapped or
memory-backed data. Its worker-pool pipeline additionally requires compressed
data, projected columns without definition or repetition levels, and either
multiple row groups or at least 500,000 rows. In the `qio` build there are no
OpenMP flags, so other batch-reader paths are serial unless that worker-pool
pipeline is active. In this snapshot the pipeline forces a minimum of two
workers, even when `num_threads = 1`; this contradicts the public configuration
comment that one disables parallelism.

Initialization is automatic and thread-safe. Custom allocator changes and
codec registration are process-wide setup operations and must not race with
runtime activity.

The library detects SIMD features at runtime. The current `qio` build enables
NEON on ARM64 and otherwise uses the portable scalar path; x86-specific SIMD
objects are compiled without the per-file feature flags needed to activate
them.

## Errors and Ownership

Fallible operations return `carquet_status_t`, a nullable handle, or a negative
count, depending on the API family. `carquet_error_t` can add a message, source
location, file offset, row-group index, and column index. Helpers provide status
names, formatted messages, recovery hints, and recoverability classifications.

Important ownership rules are:

- a schema returned by `carquet_reader_schema()` belongs to the reader;
- a buffer passed to `carquet_reader_open_buffer()` belongs to the caller and
  must remain alive and unchanged until the reader closes;
- a caller-owned `FILE*` remains the caller's responsibility;
- low-level `BYTE_ARRAY` payloads may borrow column-reader page storage;
- batch data, validity bitmaps, dictionary indexes, and dictionaries belong to
  the batch reader and must not be retained across the next batch;
- bloom filters, column indexes, and offset indexes have explicit destroy/free
  functions; and
- a writer copies its input schema.

The public header says bytes returned by `carquet_writer_get_buffer()` should be
released with `free()`. The implementation allocates those bytes through
carquet's configurable allocator. `free()` is therefore correct with the
default allocator, but the buffer API has no matching public deallocator when a
custom allocator is installed. Treat this as an upstream API inconsistency.

## Current `qio` Binding Boundary

`qio` exposes a useful but substantially smaller interface than the vendored C
library.

### Current read path

`read_parquet()` is implemented as `parquet_open(mmap = TRUE)` followed by
`collect()` and `parquet_close()`. The persistent handle API also exposes:

- `schema()`, `row_groups()`, and footer `metadata()`;
- `read_plan()` and `parquet_type_mapping()`;
- projection by leaf name for flat columns;
- row-group selection;
- checksum and thread controls;
- full-data-frame collection; and
- callback-based processing with `walk_batches()`.

`schema()` and `names()` construct dotted paths with
`carquet_schema_column_path()`, but `collect()` selection currently passes the
requested string to carquet's leaf-name-only lookup. Dotted selection of nested
columns therefore does not work, and nested or repeated columns are rejected
before materialization.

`collect()` uses carquet's low-level column readers directly and reads selected
columns in full. Its `batch_size` argument is currently unused, and one result
cannot exceed R's `INT_MAX` row limit. `walk_batches()` uses the carquet batch
reader and honors `batch_size`.

When mmap is active, `collect()` uses carquet's internal worker pool for numeric
tasks, one task per selected row-group/column pair. Strings remain on the R main
thread. Buffered reads are serial, and `collect()` respects `threads = 1`.
`walk_batches()` inherits the batch-pipeline exception described above. The
direct collect path relies on the private
`reader/worker_pool.h` header and is therefore a deliberate coupling to
carquet's implementation, not only its public API.

### Current type mappings

| Parquet type | Read by `qio` | Written by `qio` |
|---|---|---|
| `BOOLEAN` | logical | logical |
| `INT32` | integer | integer or explicit numeric schema |
| `INT32 + DATE` | `Date` | `Date` or whole-number days |
| `INT64` | double | explicit whole-number numeric schema |
| UTC `INT64 + TIMESTAMP` | UTC `POSIXct` | `POSIXct`, with configurable unit |
| `INT96` | UTC `POSIXct` | not written |
| `FLOAT` | double | explicit numeric schema |
| `DOUBLE` | double | double |
| `BYTE_ARRAY` | character, assumed UTF-8 | character or factor as `STRING` |
| `FIXED_LEN_BYTE_ARRAY` | not materialized | not written |

An `INT64` read as double can lose integer precision outside R's exact range of
plus or minus 2^53. A non-UTC `TIMESTAMP` is not converted to `POSIXct`; it falls
back to the physical `INT64` mapping and is reported as pending by
`read_plan()`.

`parquet_schema()` can explicitly request `BOOLEAN`, `INT32`, `INT64`, `FLOAT`,
`DOUBLE`, `STRING`, `DATE`, and UTC `TIMESTAMP` with millisecond, microsecond, or
nanosecond units. Writer compression is exposed, with Snappy as qio's default,
even though raw carquet defaults to uncompressed output.

### Not yet exposed by `qio`

- nested or repeated value materialization;
- row or page predicate pushdown;
- statistics, bloom-filter, and page-index inspection;
- caller-provided `FILE*` or in-memory input/output;
- append mode;
- dictionary-aware character materialization optimizations;
- custom codecs and allocators; and
- most writer page, encoding, index, checksum, and row-group tuning.

## Known v0.6.0 API and Implementation Mismatches

These points should be rechecked when updating the vendored commit:

| Public surface | Vendored implementation |
|---|---|
| `carquet_schema_find_column()` is documented as accepting dotted paths | It compares leaf names only |
| Writer comments describe Snappy/dictionary defaults | Options initialize uncompressed, and effective encoding defaults to `PLAIN` or compressed-float `BYTE_STREAM_SPLIT` |
| `carquet_batch_reader_config_t.use_mmap` suggests batch-level mapping control | The field is not read; mapping is fixed by the underlying reader |
| `num_threads = 1` is documented as disabling batch parallelism | The mmap worker-pool pipeline raises values below two to two workers |
| `get_buffer()` output is documented for `free()` | Allocation uses the configurable carquet allocator |
| Metadata APIs model external column metadata | Reading external column metadata returns `CARQUET_ERROR_NOT_IMPLEMENTED` |

## Source Map

| Area | Primary source |
|---|---|
| Public types | `src/carquet/carquet/types.h` |
| Public errors | `src/carquet/carquet/error.h` |
| Public schemas, readers, writers, and filters | `src/carquet/carquet/carquet.h` |
| Schema behavior | `src/carquet/metadata/schema.c` |
| Reader ownership and mmap | `src/carquet/reader/file_reader.c`, `src/carquet/reader/mmap_reader.c` |
| Page and column decoding | `src/carquet/reader/page_reader.c`, `src/carquet/reader/column_reader.c` |
| Batch reading and concurrency | `src/carquet/reader/batch_reader.c`, `src/carquet/reader/worker_pool.c` |
| Writer defaults, append, close, and buffers | `src/carquet/writer/file_writer.c` |
| `qio` read bridge | `src/qio_file.c`, `R/parquet-file.R`, `R/parquet-plan.R` |
| `qio` write bridge | `src/qio.c`, `R/parquet.R`, `R/parquet-schema.R` |
| Build configuration | `src/Makevars`, `src/Makevars.win` |
| Version pin and local patches | `.agents/VENDORED.md` |

## References

- [`carquet` documentation at the vendored commit](https://github.com/Vitruves/carquet/tree/06efab6dce5475a7faa86f0938d42e9078b6d440/docs)
- [Reading files](https://github.com/Vitruves/carquet/blob/06efab6dce5475a7faa86f0938d42e9078b6d440/docs/reading.md)
- [Writing files](https://github.com/Vitruves/carquet/blob/06efab6dce5475a7faa86f0938d42e9078b6d440/docs/writing.md)
- [Nested and nullable data](https://github.com/Vitruves/carquet/blob/06efab6dce5475a7faa86f0938d42e9078b6d440/docs/nested-data.md)
- [Performance and tuning](https://github.com/Vitruves/carquet/blob/06efab6dce5475a7faa86f0938d42e9078b6d440/docs/performance.md)
- [Error handling and types](https://github.com/Vitruves/carquet/blob/06efab6dce5475a7faa86f0938d42e9078b6d440/docs/error-handling.md)
- [Apache Parquet documentation](https://parquet.apache.org/docs/)
