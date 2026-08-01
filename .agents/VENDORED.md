# Vendored code

qio bundles C dependencies under `src/` and uses system zlib for Gzip. Do not
edit vendored files as ordinary package code: update from the pinned upstream
source, then reapply or upstream qio's patches.

| Library | Version | Commit | Retrieved | License |
|---|---|---|---|---|
| [carquet](https://github.com/Vitruves/carquet) | v0.6.0 | `06efab6dce5475a7faa86f0938d42e9078b6d440` | 2026-06-29 | MIT (`src/carquet/LICENSE`) |
| [zstd](https://github.com/facebook/zstd) | v1.5.7 | `f8745da6ff1ad1e7bab384bd1f9d742439278e99` | 2026-06-29 | BSD-3-Clause (`src/zstd/LICENSE`) |
| [lz4](https://github.com/lz4/lz4) | v1.10.0 | `ebb370ca83af193212df4dcbadcc5d87bc0de2f0` | 2026-06-29 | BSD-2-Clause (`src/lz4/LICENSE`) |

On Windows, Rtools supplies zlib.

## Included source

### carquet -> `src/carquet/`

Copy:

- `include/carquet/` to `src/carquet/carquet/`.
- `src/{compression,core,encoding,metadata,reader,simd,thrift,util,writer}/` to
  matching directories under `src/carquet/`.

Exclude CLI, tests, benchmarks, profiling, fuzzing, interop, examples, docs,
and build-system files.

### zstd -> `src/zstd/`

Copy from upstream `lib/`:

- `zstd.h`, `zstd_errors.h`, and `zdict.h`;
- `common/`, `compress/`, and `decompress/`.

Exclude `dictBuilder/`, `legacy/`, `deprecated/`, `dll/`, and build files.
`decompress/huf_decompress_amd64.S` is retained but not compiled.

`src/Makevars` defines:

- `XXH_NAMESPACE=ZSTD_` to avoid an xxHash symbol clash with carquet;
- `ZSTD_DISABLE_ASM=1`;
- `ZSTD_LEGACY_SUPPORT=0`.

zstd is single-threaded in qio.

### lz4 -> `src/lz4/`

Copy only `lz4.c` and `lz4.h`. Carquet uses the block API; frame, HC, file, and
separate xxHash sources are unnecessary.

## Local carquet patches

These changes are absent from the pinned upstream commit. Re-vendoring removes
them.

- **O(1) dense-value cursor** (`reader/page_reader.c`,
  `reader/reader_internal.h`). Maintain `page_dense_values_read` instead of
  rescanning prior definition levels. Reset it on page load and advance it on
  reads and partial-page skips. Covered by partial-page tests.
- **Count page nulls once** (`reader/page_reader.c`,
  `reader/column_reader.c`, `reader/reader_internal.h`). Cache
  `page_non_null_count` at decode and `last_dense_read` per read.
- **Fix scalar Snappy overlap** (`compression/snappy.c`). Use
  `big_pattern = 16`; a threshold of 8 sends 8..15-byte matches through unsafe
  16-byte copies and corrupts scalar x86 output. Covered by partial-page tests.
- **Zero decode slack** (`reader/page_reader.c`). Allocate and clear
  `CARQUET_DECODE_SLACK` after each payload so permitted group over-reads see
  defined bytes. This is defensive; the Snappy bug caused the reproduced
  corruption.
- **Propagate preload/index failures** (`reader/batch_reader.c`,
  `reader/column_reader.c`, `reader/page_filter.c`). Check column-read and
  offset-index statuses and release both indexes on page-filter failure. The
  preload path still returns a generic decode status.
- **Portable allocation format** (`reader/file_reader.c`). Use
  `PRIuMAX`/`uintmax_t`, not `%zu`, for MinGW's C runtime.
- **Correct SSE4.2 guard** (`simd/x86/sse_ops.c`). Outside MSVC, require
  `__SSE4_2__`; MinGW's `_M_X64` does not legalize SSE4.2 intrinsics without
  `-msse4.2`.
- **Honor a single-threaded batch read** (`reader/batch_reader.c`). Upstream
  raised any `num_threads` below two up to two, so `walk_batches(threads = 1)`
  still started a worker. Create no pool below two threads, which leaves
  `pipeline_active` false and takes the serial path an uncompressed file
  already uses. The public `carquet_thread_pool_create()` still forces two and
  is left alone; qio does not call it. Covered by a thread-count test in
  `tests/testthat/test-parquet-file.R`.

- **Find an undeclared dictionary page** (`reader/page_reader.c`). Some writers
  emit a dictionary page as the first page of a column chunk but declare only
  `data_page_offset`, leaving `dictionary_page_offset` unset. carquet read that
  page as a data page and failed with "Expected data page". The dictionary
  loader now falls back to `data_page_offset` when no dictionary offset is
  declared, treats the page as a dictionary only if it is one, and computes the
  first data page from the offset the dictionary was actually read at rather
  than from `col_meta->dictionary_page_offset`, which is zero in this case.
  Both the mapped and buffered paths needed it. This made two Apache reference
  fixtures readable that were not: `datapage_v2.snappy.parquet` and the flat
  columns of `nested_maps.snappy.parquet`. Covered by `test-external.R`.
- **Byte-split a page once, at finalize** (`writer/page_writer.c`).
  BYTE_STREAM_SPLIT transposes a whole page into byte planes, so it cannot be
  applied incrementally. The encoder split each call's subrange and appended,
  producing independently transposed regions that the decoder de-split as one
  stride: every value in any page built from more than one call came back
  wrong. carquet selects this encoding for `FLOAT` and `DOUBLE` whenever a
  codec is set, so it silently corrupted the default write path. Raw values now
  accumulate and `apply_byte_stream_split()` transposes the page once at
  finalize, byte-wise so it does not depend on buffer alignment. Verified
  against Apache Arrow at sizes that previously corrupted everything; covered
  by `test-qio.R`.
- **Resume BOOLEAN bit packing across write batches**
  (`writer/page_writer.c`). Parquet packs a page's booleans as one continuous
  bit stream, but `carquet_encode_plain_boolean()` always starts a fresh byte,
  so a column written in several batches restarted the stream whenever the
  running count was not a multiple of 8 and every later value landed on the
  wrong bit. Writing 1000 booleans as 5 then 995 corrupted 398 of them.
  `append_plain_boolean()` now continues from the page's bit position. Verified
  against Apache Arrow; covered by `test-qio.R`.
- **Allow an empty BOOLEAN page** (`encoding/plain.c`). A page with no present
  values needs no bytes, but `carquet_buffer_advance()` returns `NULL` for a
  zero-size request and `carquet_encode_plain_boolean()` reported that as
  `CARQUET_ERROR_OUT_OF_MEMORY`. Writing an all-null `logical` column therefore
  failed outright; every other type already handled it. The function's own
  `if (bytes_needed > 0)` guard shows a zero count was anticipated. Covered by
  the degenerate-frame tests in `tests/testthat/test-qio.R`.

`reader_internal.h` defines structs shared by multiple translation units. R's
own build rules do not track header dependencies, so `src/Makevars` and
`src/Makevars.win` declare one explicitly: every object depends on every
vendored and package header. Without it, `R CMD INSTALL` reuses stale objects
after a header edit and relinks them against a changed struct layout, with no
linker error and memory corruption at runtime.

The dependency is deliberately coarse: any header edit rebuilds everything.
Per-file dependency generation needs compiler-specific flags that are not
portable across the compilers R is built with.

Two consequences worth knowing:

- Makevars is read before R's own makefiles, so the first rule in it becomes
  make's default goal. Both files declare `all: $(SHLIB)` first; removing that
  line makes the build stop after one object instead of linking.
- `devtools::load_all()` and `pkgbuild::compile_dll()` preclean, so they
  rebuild everything regardless and cannot demonstrate this. Verify with
  `tools/check-header-deps.sh`, which uses `R CMD INSTALL`.

`find src -name '*.o' -delete` is still a valid reset, but is no longer
required after a header change.

## Upstream reporting

Every entry in the patch ledger above is a carquet bug worth reporting
upstream, and each should be rechecked on every re-vendor. The three writer
defects found in phase 5 are the most consequential, because all three
corrupted data silently rather than failing:

- BYTE_STREAM_SPLIT applied per call instead of per page,
- BOOLEAN bit packing restarting at each call,
- an empty BOOLEAN page reported as out of memory.

## Patch record

`.agents/carquet-changes.patch` is the mechanical record of every local carquet
change: applying it to pristine upstream at the pin reproduces `src/carquet`
exactly, and reversing it recovers pristine upstream. The ledger above is the
rationale; the patch is the content.

Verify with:

```sh
tools/check-vendor-drift.sh
```

It clones upstream at the pin recorded in the table above, reverse-applies the
patch to a copy of the vendored tree, and fails if anything differs. The
`vendor` workflow runs it on every push and pull request, so a vendored file
edited without updating the patch fails CI.

Regenerate the patch after deliberately changing a vendored file:

```sh
# with pristine upstream at the pin staged in the vendored layout as a/carquet,
# and the vendored tree (minus build products) as b/carquet:
diff -ruN a b > .agents/carquet-changes.patch
```

The patch is excluded from the source package along with the rest of
`.agents/`; `tools/check-vendor-drift.sh` asserts that exclusion.

## Re-vendoring

1. Check out each new tag and record its exact commit.
2. Replace only the source subsets listed above.
3. Update the version table and license files.
4. Reapply every local patch, or confirm that upstream contains an equivalent
   fix and remove its ledger entry.
5. Clean all native objects because vendored headers may have changed.
6. Build, run the focused native/interoperability tests, then run the complete
   test suite and R CMD check.

7. Regenerate `.agents/carquet-changes.patch` and confirm
   `tools/check-vendor-drift.sh` passes against the new pin.

The ledger above remains the rationale and review checklist; the patch is the
mechanical record.
