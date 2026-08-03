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

`read_parquet()` composes `open_parquet(mmap = TRUE)`, `collect()`, and
`close_parquet()`.

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
- Codec scratch must be per thread. zstd caches its contexts thread-locally on
  POSIX but kept process-global ones on Windows without OpenMP, which qio
  patches; see [`VENDORED.md`](VENDORED.md#local-carquet-patches). Recheck this
  on every update, because nothing about the API surface reveals it.

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

Readers and writers take a byte path and open it with `fopen()`, which on
Windows reads those bytes in the active code page. A path outside that page
cannot be opened at all, whatever the caller passes.

qio therefore does not use the path entry points for I/O it can own. It opens
the file itself, with `_wfopen()` on Windows, and passes the stream to
`carquet_reader_open_file()` or `carquet_writer_create_file()`. Both leave the
stream to the caller, so qio closes it after the reader or writer.

Mapping is the exception: `carquet_mmap_open()` takes a path, so a mapped read
of a path the code page cannot represent falls back to buffered I/O instead of
failing. Since buffered collects became parallel, that costs little.

Two consequences follow from owning the stream:

- `carquet_writer_abort()` deletes only a file it opened itself, so qio removes
  a partial write, with `_wremove()` on Windows.
- The writer's unwind cleanup cannot translate a path, because calling back
  into R during an unwind could jump again. `qio_path_resolve()` computes every
  form the cleanup might need before the protected window opens.

See `src/qio_path.h`.

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
| Dictionary page declared only via `data_page_offset` | fixed locally, see `VENDORED.md` |
| `RLE` as a data encoding, used for `BOOLEAN` | fixed locally, see `VENDORED.md` |

Both were fixed in the vendored tree. A dictionary page emitted as the chunk's
first page but not declared in `dictionary_page_offset` was read as a data
page. `RLE` for `BOOLEAN` was genuinely unimplemented, despite carquet's own
error hint claiming RLE is supported; it matters because Apache Arrow selects
that encoding for every `BOOLEAN` column it writes into DATA_PAGE_V2, so any
V2 file from Arrow, pyarrow, or Spark was unreadable at its boolean columns.

With both patches the reader handles every encoding in the Apache reference
corpus.

`carquet_column_read_batch()` returns a bare negative on failure, discarding
both the status and the hint its internals produced, so qio cannot report why a
column failed. It names the column's encodings from
`carquet_reader_column_chunk_metadata()` instead.

## Dictionary reads

Dictionary preservation is chosen from the first page. It works only while the
whole chunk remains dictionary encoded. A later `PLAIN` page fails; carquet
does not retry materialized output, and it does not report where it stopped.

qio's public text result is always character. Any dictionary optimization must
fall back safely for plain or mixed chunks and copy strings into R-owned memory.

**qio uses this for text columns as of v0.1.0.** Upstream exposes preservation
only through the batch reader's config, so two accessors were added locally
(see [`VENDORED.md`](VENDORED.md)) to reach it from a column reader, which is
what `collect()` uses. The flow per column chunk is:

1. Consult the footer. Skip the attempt entirely unless the chunk advertises a
   dictionary page, which also keeps non-dictionary encodings away from
   preserve mode.
2. Enable preservation, then read zero values -- that loads the first page, and
   with it the dictionary, without consuming rows.
3. Build the dictionary's CHARSXPs once, validating UTF-8 once per distinct
   value rather than once per row.
4. Read `uint32` indices and gather with `SET_STRING_ELT`.

If any step declines, or a later page is not dictionary encoded, qio frees the
reader and re-reads the whole chunk on a fresh one. A column reader has no
rewind, and preserve mode may have consumed pages before failing. That re-read
costs about 10% on files Apache Arrow writes, because Arrow emits a dictionary
page even for all-distinct columns and then falls back to `PLAIN` mid-chunk.
Switching at the page boundary instead is v0.2.0 work and needs carquet to
report the boundary rather than failing the read.

**Two hazards worth knowing before touching this.**

The value buffer is sized for `uint32` indices whenever preservation is on, but
`decode_phase3_values()` writes materialized physical values -- a
`carquet_byte_array_t` is four times wider. Upstream guarded `PLAIN` and `RLE`
at their own call sites but not `DELTA_*` or `BYTE_STREAM_SPLIT`, so a delta
page read in preserve mode overran the buffer and corrupted the heap. Patched
to refuse at the function's entry, and the footer check in step 1 means qio
never reaches it anyway.

The three paths -- indices, an abandoned attempt with a re-read, and no attempt
-- return byte-identical data, so no test comparing values can tell them apart.
`qio_read_path_counters()` exists for that, and `test-external.R` asserts the
path each fixture takes.

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
  target; an explicit boundary needs `carquet_writer_new_row_group()`. qio
  leaves the byte target alone and calls the explicit boundary, because
  `write_parquet(row_group_size =)` counts rows, which is what a caller can
  reason about.
  The automatic flush fires only when every column sits at the same logical
  row. qio writes a column at a time, so under its old column-major order that
  never happened before the last column and every file was one row group.
  Writing is now row-group-major for the same reason.
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
| Independent column readers decode concurrently | True except through zstd on Windows, where the decompression context was process-global; patched locally |
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
