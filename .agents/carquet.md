# carquet integration notes

qio vendors carquet v0.6.0 at
`06efab6dce5475a7faa86f0938d42e9078b6d440`. Local patches are listed in
[`VENDORED.md`](VENDORED.md). The vendored source plus those patches is
authoritative; upstream `main` may describe different behavior.

This file records constraints that matter to qio. Public qio scope belongs in
[`roadmap.md`](roadmap.md), and R type behavior in [`TYPES.md`](TYPES.md).
Carquet capabilities do not imply qio support.

Primary public headers:

- `src/carquet/carquet/carquet.h`: schemas, readers, writers, metadata, filters.
- `src/carquet/carquet/types.h`: physical/logical types, encodings, codecs.
- `src/carquet/carquet/error.h`: statuses and contextual errors.

## Storage model

Carquet works with physical leaf-column streams:

```text
file
`-- row group
    `-- leaf column chunk
        `-- encoded and compressed pages
```

Each stream contains dense present values plus definition levels for nullability
and repetition levels for nesting. The schema supplies maximum levels.
Reconstructing lists, maps, or structs requires all four inputs; carquet does
not return nested row objects.

The library supports every Parquet physical type and modern/legacy logical
annotations. Schemas can contain arbitrary groups and standard list, map, and
variant layouts.

## qio reader paths

`read_parquet()` composes `parquet_open(mmap = TRUE)`, `collect()`, and
`parquet_close()`.

`collect()` uses low-level column readers. It reads dense values and definition
levels, then scatters them through type-specific paths. This avoids expanding
with the batch reader only to undo that representation. Selected columns are
currently read in full: `batch_size` is unused, and one result cannot exceed
R's `INT_MAX` row limit.

`walk_batches()` uses the batch reader and honors `batch_size`. It supports
projection, row-group callbacks, page filters, thread settings, reusable pools,
and optional dictionary-preserving output.

Both paths feed the shared R conversion plan. Values returned to R must own
their memory before a column or batch reader advances.

## Column identity

`carquet_schema_find_column()` compares leaf names only, despite its header
claim that dotted paths work. Duplicate leaf names are ambiguous.

`schema()` and `names()` can obtain complete paths with
`carquet_schema_column_path()`, but `collect()` currently passes requested
strings to the leaf-name lookup. qio must resolve complete paths to leaf indexes
before calling carquet.

Use leaf indexes for projected nested or duplicate-name schemas.

## Nested streams

The schema API reports path components and maximum definition/repetition
levels. Two helpers are narrower than their names may suggest:

- `carquet_count_rows()` counts repetition-level-zero entries.
- `carquet_list_offsets()` uses repetition levels only.

Neither helper inspects definition levels, so neither distinguishes null lists,
empty lists, null elements, or nullable structs. qio owns nested assembly and
null semantics. The current release boundary is in
[`TYPES.md`](TYPES.md#nested-release-boundary).

## Reader ownership and concurrency

Readers can open paths, caller-owned `FILE*` values, or caller-owned buffers.
The caller must keep a buffer alive and unchanged until close. A schema returned
by `carquet_reader_schema()` belongs to its reader.

Low-level `BYTE_ARRAY` payloads may point into mapped input or retained page
storage. Batch values, validity maps, dictionary indexes, and dictionaries also
belong to their reader. Copy all such data before advancing or closing it.
Indexes and bloom filters have explicit destroy functions.

Concurrency rules:

- Independent reader handles may run concurrently.
- Column readers sharing mapped or memory-backed input may decode concurrently.
- Column readers sharing buffered `FILE*` state must remain serial.
- A single column reader, batch reader, or writer requires external
  synchronization.
- Allocator and codec registration are process-wide setup operations.

Mapped `collect()` schedules numeric row-group/column tasks on carquet's private
worker pool; strings remain on R's main thread. Buffered `collect()` is serial.
The direct path respects `threads = 1`.

The batch reader parallelizes only mapped or memory-backed input. Its worker
pipeline also requires every projected column to be non-nullable and
non-repeated, compression on at least one of them, and either multiple row
groups or at least 500,000 rows. A file failing any of these reads serially
whatever `threads` says — which is why most fixtures never reach the pool.

`num_threads = 1` is honored: qio patches the pipeline to create no pool below
two threads. See [`VENDORED.md`](VENDORED.md#local-carquet-patches).

qio deliberately includes private `reader/worker_pool.h`; recheck that coupling
on every carquet update. Its queue holds 512 tasks and `submit()` blocks when
full, so `collect()` primes the queue, decodes strings on the main thread, and
submits the remainder afterwards rather than submitting everything up front.

## File paths

Readers and writers take a byte path and open it with `fopen()`. qio passes
`Rf_translateChar()` output, which is the native encoding, so on Windows a path
outside the active ANSI code page cannot be opened. Supporting those paths needs
wide-character entry points upstream; until then it is a documented limitation.

## Reader performance controls

The main controls are projection, batch size, mapping, threads, and file
layout. Zero-copy reads require mapped, required, non-repeated, uncompressed,
`PLAIN` fixed-width columns (`INT32`, `INT64`, `INT96`, `FLOAT`, `DOUBLE`, or
`FIXED_LEN_BYTE_ARRAY`). `BOOLEAN` and `BYTE_ARRAY` are excluded.

For buffered or remote-like storage, `carquet_reader_prebuffer()` can coalesce
selected chunks within one row group.

The qio build enables NEON on ARM64. x86 objects lack the per-file flags needed
to activate their SIMD paths and normally use scalar code.

## Encodings the reader cannot handle

Established against `datapage_v2.snappy.parquet`, which Apache Arrow reads
without trouble:

| Encoding | Status |
|---|---|
| `PLAIN`, `PLAIN_DICTIONARY`, `RLE_DICTIONARY` in DATA_PAGE (v1) | works |
| `DELTA_BINARY_PACKED` | works, including in DATA_PAGE_V2 |
| `BYTE_STREAM_SPLIT` | works |
| Dictionary inside a DATA_PAGE_V2 page | fails: "Expected data page" |
| `RLE` as a data encoding, used for `BOOLEAN` | fails: "Unsupported encoding: 3" |

The second is genuinely unimplemented, though carquet's own error hint claims
RLE is supported. The first looks like a bug rather than a gap: the V2 path
handles `RLE_DICTIONARY`, but `load_next_page_*` recomputes the first data page
offset as dictionary offset plus header plus compressed size, overriding the
offset declared in the column chunk. That heuristic exists for writers that
declare it wrongly, and it appears to misfire here.

`carquet_column_read_batch()` returns a bare negative on failure, discarding
both the status and the hint its internals produced, so qio cannot report why a
column failed. It names the column's encodings from
`carquet_reader_column_chunk_metadata()` instead.

## Dictionary reads

Dictionary preservation is chosen from the first page. It works only while the
whole chunk remains dictionary encoded. A later `PLAIN` page fails with
`CARQUET_ERROR_INVALID_ENCODING`; carquet does not retry materialized output.

qio's public text result is always character. Any dictionary optimization must
fall back safely for plain or mixed chunks and copy strings into R-owned memory.

## Writer boundary

qio resolves R input and explicit schemas before calling carquet. Carquet copies
the schema at writer creation and owns physical encoding, compression, pages,
and row groups.

The writer supports path, caller-owned `FILE*`, and internal-buffer output.
Columns are written as dense values plus levels and must advance by equal
logical row counts before a row group ends.

Important defaults and controls:

- The carquet default is uncompressed `PLAIN` output.
- With compression, `FLOAT` and `DOUBLE` default to `BYTE_STREAM_SPLIT`.
- Dictionary encoding is effective only through
  `carquet_writer_set_column_encoding()`; the global option is unused.
- Per-column overrides cover encoding, compression, pages, statistics, and
  bloom filters.
- Global options also cover row groups, checksums, indexes, metadata version,
  and timestamp coercion.
- `writer_options.row_group_size` is a target in **bytes** (default 128MB), and
  carquet flushes a row group when it is exceeded. There is no row-count
  target; an explicit boundary needs `carquet_writer_new_row_group()`. qio sets
  neither today, so every qio-written file under 128MB is a single row group.
- Requested legacy `LZ4` is written as `LZ4_RAW`.

qio independently defaults to Snappy. Its planned configuration object is
specified in [`roadmap.md`](roadmap.md#writer-configuration).

Append mode compares leaf count/order, names, physical types, repetition, fixed
widths, and logical-type IDs. It does not compare parent paths or logical
parameters such as decimal scale, timestamp unit, integer signedness, or CRS.
Strict callers must validate those separately.

Writer lifecycle:

```text
create -> configure -> write -> close
                         `-> abort before close after a write failure
```

For path and `FILE*` output, `close()` frees the writer even on error; never
abort afterward. Buffer writers remain alive after close so `get_buffer()` can
transfer bytes and free the handle.

`get_buffer()` is documented for `free()`, but allocation uses carquet's
configurable allocator. `free()` is valid only with the default allocator; the
public API exposes no matching deallocator for custom allocators.

## Pruning and metadata

Carquet exposes row-group statistics, bloom filters, column indexes, offset
indexes, and page filters. Page filters prune pages conservatively; callers
must still apply exact row predicates. Predicate columns need page indexes but
need not be projected. `INT96` has no defined sort order and cannot be filtered.

Metadata includes footer key/value pairs, chunk encodings/compression, index
availability, sorting declarations, and geospatial bounds. External column
metadata files are modeled but not implemented.

## API mismatches to recheck on update

| Public surface | Vendored behavior |
|---|---|
| Dotted paths in `carquet_schema_find_column()` | Leaf-name comparison only |
| Snappy/dictionary writer defaults in comments | Uncompressed; `PLAIN` or compressed-float `BYTE_STREAM_SPLIT` |
| `batch_reader_config.use_mmap` | Initialized but ignored; mapping is fixed at reader open |
| `num_threads = 1` disables parallelism | Public `carquet_thread_pool_create()` still forces two; the batch pipeline is patched locally to honor one |
| `carquet_worker_pool_submit()` "Non-blocking" | Blocks once the 512-slot queue is full |
| `carquet_worker_pool_wait()` | No timeout, so it cannot be interrupted |
| BYTE_STREAM_SPLIT encodes a page | Each call's subrange is split separately and appended, corrupting any multi-call page |
| `write_batch()` may be called repeatedly per column | `BOOLEAN` bit packing and BYTE_STREAM_SPLIT do not resume across calls |
| `get_buffer()` bytes use `free()` | Bytes use the configured allocator |
| External column metadata APIs | Return `CARQUET_ERROR_NOT_IMPLEMENTED` |

## Source map

| Area | Source |
|---|---|
| Public API | `src/carquet/carquet/{carquet,types,error}.h` |
| Schema behavior | `src/carquet/metadata/schema.c` |
| Reader ownership and mmap | `src/carquet/reader/{file_reader,mmap_reader}.c` |
| Page/column decode | `src/carquet/reader/{page_reader,column_reader}.c` |
| Batch concurrency | `src/carquet/reader/{batch_reader,worker_pool}.c` |
| Writer behavior | `src/carquet/writer/file_writer.c` |
| qio read bridge | `src/qio_file.c`, `R/parquet-file.R`, `R/parquet-plan.R` |
| qio write bridge | `src/qio.c`, `R/parquet.R`, `R/parquet-schema.R` |
| Build flags | `src/Makevars`, `src/Makevars.win` |
| Pins and patches | `.agents/VENDORED.md` |

Upstream documentation for the pinned commit is under its
[`docs/` directory](https://github.com/Vitruves/carquet/tree/06efab6dce5475a7faa86f0938d42e9078b6d440/docs).
