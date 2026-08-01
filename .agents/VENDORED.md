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

## Known upstream defects worked around in qio

These are carquet bugs qio avoids rather than patches. Each one should be
reported upstream and rechecked on every re-vendor.

### BYTE_STREAM_SPLIT corrupts any page written in more than one call

`writer/page_writer.c`, `encode_double_values()` and `encode_float_values()`.

BYTE_STREAM_SPLIT transposes a whole page into byte planes: every value's first
byte, then every value's second byte, and so on. The encoder instead splits
each call's subrange on its own and appends the result, so a page assembled
from two calls holds two independently transposed regions. The decoder
de-splits the concatenation as a single stride, and every value in the page
comes back wrong.

carquet selects this encoding automatically for `FLOAT` and `DOUBLE` whenever a
compression codec is set, which is qio's default. The effect was silent
corruption of the written file, not a read error: Apache Arrow reads the same
wrong values back.

Reproduced with a nullable double column past roughly a megabyte of present
values -- 171,428 of 200,000 values wrong, every non-null one. Non-nullable
columns of the same size were unaffected, so the trigger is how many separate
encode calls a page receives, not size alone.

**Workaround:** `src/qio.c` calls `carquet_writer_set_column_encoding()` to
force `CARQUET_ENCODING_PLAIN` for `FLOAT` and `DOUBLE`. Measured cost: none
worth reporting; a 200,000-row random double column is 1.53MB with PLAIN plus
Snappy against 1.79MB from Arrow's own default. Covered by `test-qio.R`.

### Multiple write batches per column corrupt some encodings

Related, and the reason writes are not yet chunked. Calling
`carquet_writer_write_batch()` several times for one column corrupts
`BOOLEAN` columns, whose bit packing does not resume correctly across calls,
and corrupted `FLOAT`/`DOUBLE` through the encoder above. `INT32`, `INT64`, and
`BYTE_ARRAY` round-tripped correctly in the same test.

This blocks bounding the writer's scratch memory and adding interrupt checks,
since both need a column to be written in pieces. Re-verify every physical type
before attempting it again.

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
