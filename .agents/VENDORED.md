# Vendored code

qio bundles C dependencies under `src/` and uses system zlib for Gzip. Do not
edit vendored files as ordinary package code: change them on the carquet fork,
then re-vendor from it.

| Library | Version | Commit | Retrieved | License |
|---|---|---|---|---|
| [carquet](https://github.com/Vitruves/carquet) | v0.6.0 | `06efab6dce5475a7faa86f0938d42e9078b6d440` | 2026-06-29 | MIT (`src/carquet/LICENSE`) |
| [carquet fork](https://github.com/pedrobtz/carquet) | `qio` branch | `482e2cc5bab4a18e74bf2fde6a73be515d2b532b` | 2026-08-06 | MIT (`src/carquet/LICENSE`) |
| [zstd](https://github.com/facebook/zstd) | v1.5.7 | `f8745da6ff1ad1e7bab384bd1f9d742439278e99` | 2026-06-29 | BSD-3-Clause (`src/zstd/LICENSE`) |
| [lz4](https://github.com/lz4/lz4) | v1.10.0 | `ebb370ca83af193212df4dcbadcc5d87bc0de2f0` | 2026-06-29 | BSD-2-Clause (`src/lz4/LICENSE`) |

On Windows, Rtools supplies zlib.

## The carquet fork

qio does not vendor from upstream carquet directly. It vendors from
[`pedrobtz/carquet`](https://github.com/pedrobtz/carquet), a fork that sits
between this package and upstream:

```
main   ──●──●──●──●   mirror of Vitruves/carquet, kept current
            │
 qio        └──●──●──●──●   the upstream pin plus one commit per local patch
               │
 fix/…         └──●          one branch, one commit, one upstream pull request
```

- **`main`** is a pure mirror. It is only ever fast-forwarded from upstream, so
  GitHub's fork-sync works and every topic branch starts from pristine code.
- **`qio`** is what `src/carquet` is copied from. It is based on the *upstream
  pin* in the table above, not on `main`'s tip, and carries exactly one commit
  per entry in the patch ledger below. `git log <upstream-pin>..qio` is the
  ledger in executable form.
- **`fix/…`** branches are cut from `main` for upstreaming. See
  [Upstream reporting](#upstream-reporting).

Two properties make this worth the indirection over a patch file:

- Every local change is a reviewable commit with a message that explains the
  defect, so preparing a pull request is a cherry-pick rather than an
  archaeology exercise.
- Re-vendoring becomes `git rebase` onto the new upstream, which reports a
  conflict where upstream changed the same code and drops a patch that upstream
  has since fixed. A flat patch file could only fail to apply.

`tools/check-vendor-drift.sh` enforces the whole arrangement; see
[Drift](#drift).

## Included source

### carquet -> `src/carquet/`

Copy from the fork's `qio` branch at the pin above:

- `include/carquet/` to `src/carquet/carquet/`.
- `src/{compression,core,encoding,metadata,reader,simd,thrift,util,writer}/` to
  matching directories under `src/carquet/`.
- `LICENSE` to `src/carquet/LICENSE`.

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

These changes are absent from the pinned upstream commit. Each is one commit on
the fork's `qio` branch, listed here in the order they are applied. The commit
is the content; the entry below is the rationale and the review checklist.

Not every entry is a defect. Four are optimizations qio wanted, one is an API
addition, and one is defensive hardening whose motivating corruption had another
cause. The rest are bugs.

### Transpose BYTE_STREAM_SPLIT once per page (`22edb41`)

`writer/page_writer.c`. **Silent data corruption.** BYTE_STREAM_SPLIT transposes
a whole page into byte planes, so it cannot be applied incrementally. The
encoder split each call's subrange and appended, producing independently
transposed regions that the decoder de-split as one stride: every value in any
page built from more than one call came back wrong. carquet selects this
encoding for `FLOAT` and `DOUBLE` whenever a codec is set, so it silently
corrupted the default write path. Raw values now accumulate and
`apply_byte_stream_split()` transposes the page once at finalize, byte-wise so
it does not depend on buffer alignment. Verified against Apache Arrow at sizes
that previously corrupted everything; covered by `test-qio.R`. Covers `FLOAT`
and `DOUBLE` only; the next entry extends it to the other three types the
encoding supports. Upstream would receive the two as a single pull request —
`fix/byte-stream-split-per-page` is already combined.

### Extend the BYTE_STREAM_SPLIT transposition to INT32/INT64/FLBA (`482e2cc`)

`writer/page_writer.c`. **Silent data corruption, introduced by the previous
entry.** That patch moved the transposition to finalize but only removed the
incremental encoder paths for `FLOAT` and `DOUBLE`. carquet supports the
encoding for `INT32`, `INT64` and `FIXED_LEN_BYTE_ARRAY` too, and those three
kept splitting per call and appending — then `apply_byte_stream_split()`, which
runs for any column whose encoding is BYTE_STREAM_SPLIT, transposed them a
second time at a width taken from a `FLOAT`-or-`DOUBLE` ternary rather than from
the column's own type.

**Not reachable from qio**, which is why it survived: carquet's default encoding
selector chooses BYTE_STREAM_SPLIT only for `FLOAT` and `DOUBLE`, and qio's sole
`carquet_writer_set_column_encoding()` call is `RLE_DICTIONARY` on `BYTE_ARRAY`
columns. The three types get the encoding only from a caller that asks for it
explicitly. Fixed anyway, because the vendored library should not be broken for
such a caller, and because it would become reachable the moment qio exposed an
encoding option.

The width now comes from the physical type, using `type_length` for
`FIXED_LEN_BYTE_ARRAY`. Found by carquet's own `bss_int32`, `bss_int64` and
`bss_flba` roundtrip tests, which fail on the previous entry and pass here —
qio's suite never exercised the path, and neither did anything in this
repository. Running the vendored library's own test suite against the series is
now part of re-vendoring for exactly this reason.

### Resume BOOLEAN bit packing across write batches (`0760cef`)

`writer/page_writer.c`. **Silent data corruption.** Parquet packs a page's
booleans as one continuous bit stream, but `carquet_encode_plain_boolean()`
always starts a fresh byte, so a column written in several batches restarted the
stream whenever the running count was not a multiple of 8 and every later value
landed on the wrong bit. Writing 1000 booleans as 5 then 995 corrupted 398 of
them. `append_plain_boolean()` now continues from the page's bit position.
Verified against Apache Arrow; covered by `test-qio.R`.

### Fix scalar Snappy overlap (`77b9493`)

`compression/snappy.c`. **Silent data corruption.** Use `big_pattern = 16`; a
threshold of 8 sends 8..15-byte matches through unsafe 16-byte copies and
corrupts scalar x86 output. Covered by partial-page tests. **Fixed upstream in
v0.7.0** — retire this patch at the next re-vendor.

### Give every thread its own zstd context on Windows (`5808919`)

`compression/zstd.c`, `reader/worker_pool.c`. **Memory-unsafe.** zstd contexts
are cached per thread because they cost about 650KB to create. Upstream used a
`pthread_key` on POSIX, `__declspec(thread)` on Windows with OpenMP, and a pair
of **process-global** `ZSTD_DCtx`/`ZSTD_CCtx` on Windows without it — on the
assumption that no OpenMP means no threads. carquet's own worker pool disproves
that: it creates threads on Windows whether or not OpenMP is configured. qio's
mapped `collect()` decodes numeric columns on that pool while decoding strings
on the main thread, so two threads drove one shared decompression context at
once. Reading any multi-column zstd file on Windows therefore failed to decode
or killed the R process outright, and it is Windows-only: the POSIX branch was
always correct. Windows now uses thread-local storage regardless of OpenMP.
Because that storage has no destructor and qio creates a pool per read, each
worker frees its own contexts as it exits, which also removes a leak the OpenMP
branch always had. Covered by the writer round-trip tests in `test-qio.R`, which
read zstd files with several columns. **Fixed upstream in v0.7.0** by a
different mechanism (`TlsAlloc`/`TlsGetValue` rather than `__declspec(thread)`)
— retire this patch at the next re-vendor and re-verify on Windows.

### Refuse dictionary preservation for non-dictionary encodings (`2276c5b`)

`reader/page_reader.c`. **Memory-unsafe.** `decode_phase3_values()` writes
materialized physical values, but its caller sizes the value buffer for
`uint32_t` indices whenever `preserve_dictionary` is set. A
`carquet_byte_array_t` is four times wider than a `uint32_t`, so a
`DELTA_BYTE_ARRAY`, `DELTA_LENGTH_BYTE_ARRAY` or `BYTE_STREAM_SPLIT` page read
in preserve mode overran the buffer and corrupted the heap. Upstream guards
`PLAIN` and `RLE` at their own call sites but not these. None of the encodings
that function handles is a dictionary encoding, so a single refusal at its entry
is complete. Found as an intermittent SIGSEGV/SIGBUS in qio's suite and bisected
to `parquet/delta_encodings.parquet`; `gctorture` was clean, which is what
identified it as a buffer overrun rather than a protection fault.

### Find an undeclared dictionary page (`ebdb9c4`)

`reader/page_reader.c`. Some writers emit a dictionary page as the first page of
a column chunk but declare only `data_page_offset`, leaving
`dictionary_page_offset` unset. carquet read that page as a data page and failed
with "Expected data page". The dictionary loader now falls back to
`data_page_offset` when no dictionary offset is declared, treats the page as a
dictionary only if it is one, and computes the first data page from the offset
the dictionary was actually read at rather than from
`col_meta->dictionary_page_offset`, which is zero in this case. Both the mapped
and buffered paths needed it. This made two Apache reference fixtures readable
that were not: `datapage_v2.snappy.parquet` and the flat columns of
`nested_maps.snappy.parquet`. Covered by `test-external.R`.

### Decode RLE as a BOOLEAN data encoding (`d23708b`)

`reader/page_reader.c`. Parquet allows `RLE` for `BOOLEAN` values, and Apache
Arrow selects it for every `BOOLEAN` column it writes into DATA_PAGE_V2. carquet
implemented `RLE` only for levels and dictionary indexes, so such a column
failed with "Unsupported encoding: 3" even though the library's own error hint
claims RLE is supported. `decode_phase3_values()` now handles it for both page
versions: the payload is a 4-byte little-endian length followed by the hybrid
run stream at bit width 1, decoded in fixed slices so a page needs no
allocation. Unlike the level sections, the length prefix is present in V2 as
well. The case is rejected for non-`BOOLEAN` types and in dictionary-preserving
mode, where the destination is sized for `uint32_t`. Verified against pyarrow;
covered by `test-external.R` and `parquet/rle_boolean.parquet`. Only the V2 path
has a fixture: no mainstream writer emits RLE booleans into a V1 page, so there
is nothing independent to test the V1 branch against. **Fixed upstream in
v0.7.0** — retire this patch at the next re-vendor and confirm the fixture still
reads.

### Accept a legal DELTA_BINARY_PACKED block size (`7b375bc`)

`encoding/delta.c`. The decoder validated every header against the shape its own
encoder writes, 128 values in four mini-blocks, and rejected anything larger.
Apache Arrow writes 256 values per block for 64-bit columns while writing 128
for 32-bit ones, so every `INT64` delta column from Arrow failed as "unsupported
encoding" while the `INT32` ones read fine. The single delta column in the
Apache reference corpus is `INT32`, which is why this survived. The decoder now
has its own bounds, wider than the encoder's, with the buffers sized for the
worst case they permit; the encoder still writes the smallest legal shape.
Covered by `parquet/delta_encodings.parquet` and `test-external.R`. **Fixed
upstream in v0.7.0**, which validates against the specification rather than
against its own encoder — retire this patch at the next re-vendor.

### Allow an empty BOOLEAN page (`6a75734`)

`encoding/plain.c`. A page with no present values needs no bytes, but
`carquet_buffer_advance()` returns `NULL` for a zero-size request and
`carquet_encode_plain_boolean()` reported that as
`CARQUET_ERROR_OUT_OF_MEMORY`. Writing an all-null `logical` column therefore
failed outright; every other type already handled it. The function's own
`if (bytes_needed > 0)` guard shows a zero count was anticipated. Covered by the
degenerate-frame tests in `test-qio.R`.

### Portable allocation format (`be666ff`)

`reader/file_reader.c`. Use `PRIuMAX`/`uintmax_t`, not `%zu`, for MinGW's C
runtime.

### Correct SSE4.2 guard (`69653e1`)

`simd/x86/sse_ops.c`. Outside MSVC, require `__SSE4_2__`; MinGW's `_M_X64` does
not legalize SSE4.2 intrinsics without `-msse4.2`.

### Honor a single-threaded batch read (`ce2e574`)

`reader/batch_reader.c`. Upstream raised any `num_threads` below two up to two,
so `walk_batches(threads = 1)` still started a worker. Create no pool below two
threads, which leaves `pipeline_active` false and takes the serial path an
uncompressed file already uses. The public `carquet_thread_pool_create()` still
forces two and is left alone; qio does not call it. Covered by a thread-count
test in `test-parquet-file.R`.

### Propagate preload/index failures (`72e1684`)

`reader/batch_reader.c`, `reader/column_reader.c`, `reader/page_filter.c`. Check
column-read and offset-index statuses and release both indexes on page-filter
failure. The preload path still returns a generic decode status.

### Zero decode slack (`b4fb62e`)

`reader/page_reader.c`. Allocate and clear `CARQUET_DECODE_SLACK` after each
payload so permitted group over-reads see defined bytes. This is defensive; the
Snappy bug caused the reproduced corruption.

### Expose dictionary preservation on a column reader (`4491443`)

`carquet/carquet.h`, `reader/column_reader.c`. **API addition, not a fix.**
Upstream reaches `preserve_dictionary` only from the batch reader's config, so a
column reader obtained from `carquet_reader_get_column()` — which is what qio's
`collect()` uses — could not ask for indices instead of materialized values.
Adds `carquet_column_set_preserve_dictionary()` and
`carquet_column_get_dictionary()`, both of which only expose state the reader
already maintains. The getter also reports the dictionary's byte size, which
upstream's batch-reader equivalent does not: the offset table and the length
prefixes come from the file, so a caller cannot bounds-check an entry without
it. Covered by `parquet/dict_nulls.parquet` and `test-external.R`.

### Stop rescanning definition levels on every read (`aac02da`)

`reader/page_reader.c`, `reader/column_reader.c`, `reader/reader_internal.h`.
**Performance, not a defect.** Reading a nullable page in K batches rescanned
its definition levels twice per batch: once to find the dense start offset, by
counting present values over `[0, page_values_read)`, and again to count the
present values in the batch just produced. The first is quadratic — consuming
one page in K batches costs O(N^2/K) in the page's value count. Three fields
replace the scans: `page_dense_values_read` (the dense cursor, advanced on reads
and partial-page skips, reset at the single choke point for a fresh page load),
`page_non_null_count` (the page total, counted once at decode, which lets a
whole-page read skip counting entirely), and `last_dense_read` (the present
values from the most recent call, so the column reader advances without
recounting). Covered by partial-page tests that read at batch sizes straddling
page boundaries.

### Unpack whole RLE groups into the caller's buffer (`0556bd0`)

`encoding/rle.c`. **Performance, not a defect.**
`carquet_rle_decoder_get_batch()` unpacked eight values into a staging buffer
and copied them out one at a time with three loop conditions per value. Whole
groups now go straight to the destination; the staging buffer still carries a
partial group across calls, and it is drained first so a call that stopped
mid-group cannot reorder values. The unpack kernel is also resolved once per
batch rather than once per eight values. Worth 5-9%, and 1.8% more from the
hoist. Covered by reading every fixture at batch sizes deliberately off the
eight-value group boundary.

### Unpack bit widths 9-32 with a 64-bit accumulator (`67abf61`)

`core/bitpack.c`. **Performance, not a defect.** Widths 1-8 and 16 have
specialized or SIMD kernels; every other width — which is every dictionary with
more than 256 entries — went through a loop that took one byte at a time and did
two `% 8` operations per byte. The undecoded bits now sit in a 64-bit
accumulator refilled a byte at a time, so each value costs one mask and one
shift. Worth 15-25% on the affected widths and nothing on width 8, which is the
control. Verified bit-exact against the previous algorithm over 4,800,000
unpacks by `tools/bitunpack-differential.c`. **Superseded upstream in v0.7.0**,
which rewrote the same kernel around a 64-bit word with shift/mask. Retire at
the next re-vendor unless a benchmark shows the rolling accumulator still wins.

## Header dependencies

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

## Drift

```sh
tools/check-vendor-drift.sh
```

It clones the fork, fetches upstream into the same clone, and asserts three
things:

1. `src/carquet` matches the fork at the fork pin, file for file.
2. The upstream pin is an ancestor of the fork pin, so the series really is
   built on the recorded upstream commit.
3. The fork carries exactly as many commits over the upstream pin as this file
   has patch entries, so a commit added to the fork without a ledger entry —
   or an entry without a commit — fails here.

The `vendor` workflow runs it on every push and pull request. A vendored file
edited in place, rather than on the fork, fails CI.

**Never edit `src/carquet` directly.** Make the change on the fork's `qio`
branch, push it, re-copy, and update the fork pin in the table above.

## Upstream reporting

**Nothing here has been reported upstream yet.** No issue or pull request exists
for any of these. When one is opened, record its number beside the ledger entry
so a re-vendor can tell what upstream has already taken.

A pull request is prepared from `main`, not from `qio`, so that it carries one
fix and nothing else:

```sh
cd ../carquet
git fetch upstream && git checkout main && git merge --ff-only upstream/main
git checkout -b fix/short-name main
git cherry-pick <commit-from-the-qio-branch>
# scrub the qio-specific comment references (see below), then:
git push -u origin fix/short-name
gh pr create --repo Vitruves/carquet --base main
```

Two things to fix in the cherry-picked commit before pushing:

- Several patches carry comments that say `qio patch:` or point at
  `.agents/VENDORED.md`. Those are meaningful in this repository and meaningless
  upstream. Rewrite them to describe the code rather than its provenance. The
  `qio` branch keeps them verbatim, because the drift check requires it to match
  `src/carquet` exactly.
- A cherry-pick onto current upstream is not automatically still correct. Two of
  them needed real rework against v0.7.0; see the branch table.

### Prepared branches

Thirteen branches are cut, built, and pushed to the fork, each one commit on
top of upstream `main` at `v0.7.0_2`, with the qio-specific comments scrubbed.
Every one builds and passes upstream's own suite (39 tests). **No pull request
has been opened.**

| Branch | Notes |
|---|---|
| `fix/preserve-dictionary-overrun` | The heap overrun. Send this one first. |
| `fix/byte-stream-split-per-page` | **Reworked**, see below. Adds 5 regression tests. |
| `fix/boolean-bit-packing-across-batches` | **Reworked**: upstream moved the PLAIN path under an RLE branch. Adds a regression test. |
| `fix/undeclared-dictionary-page` | Clean cherry-pick. |
| `fix/empty-boolean-page` | Clean cherry-pick. |
| `fix/mingw-printf-format` | Clean cherry-pick. |
| `fix/mingw-sse42-guard` | Clean cherry-pick. |
| `fix/serial-batch-read` | Clean cherry-pick. |
| `fix/propagate-preload-failures` | **Reworked**: uses upstream's new `carquet_column_read_batch_ex()` error rather than changing the old wrapper's return contract. |
| `harden/zero-decode-slack` | Defensive only; offer last, or not at all. |
| `feat/column-preserve-dictionary` | API addition, not a fix. |
| `perf/def-level-rescan` | Optimization; the quadratic rescan is still present upstream. |
| `perf/rle-whole-groups` | Optimization. Needs a benchmark against v0.7.0's rewritten `rle.c` before it is worth offering. |

Two findings from preparing them are worth carrying into the next re-vendor:

- **BYTE_STREAM_SPLIT is broken for five types, not two** — upstream, and until
  `482e2cc` here as well. v0.6.0 already supported the encoding for `INT32`,
  `INT64` and `FIXED_LEN_BYTE_ARRAY`; v0.7.0 kept them and reproduced the same
  per-call transposition defect on each. The prepared branch carries the
  combined fix for all five.
- **The RLE BOOLEAN branch upstream has the same shape of bug.** It appends a
  fresh length-prefixed RLE block per `add_values` call, so a page written in
  several calls holds several concatenated streams and the reader sees only the
  first. Not investigated further and not part of any prepared branch.

The first of those was found by running carquet's own test suite, not qio's.
The fork's CI runs it on every push, which is what surfaced it: the `qio` branch
went red on `bss_int32`, `bss_int64` and `bss_flba` while every qio test and
`R CMD check` stayed green, because nothing qio does reaches the encoding for
those types. **Run the vendored library's suite against the series when
re-vendoring** — `cmake -B build -DCARQUET_BUILD_TESTS=ON && ctest --test-dir
build` — and treat the fork's CI as a gate, not decoration.

Report roughly in this order, worst first:

**Silent data corruption** — the caller gets wrong values and no error:

- BYTE_STREAM_SPLIT applied per call instead of per page. Affects the default
  path: carquet selects it for `FLOAT`/`DOUBLE` whenever a codec is set.
- BOOLEAN bit packing restarting at each call rather than continuing the page.

**Memory-unsafe** — corrupts or ends the process:

- dictionary-preserving mode decoding a non-dictionary page into a buffer sized
  for `uint32_t` indices, overrunning it by 4x for any BYTE_ARRAY encoding.

**Valid files rejected** — no data loss, but the file cannot be read or written
at all:

- a dictionary page declared only through `data_page_offset`, read as a data
  page; two Apache reference fixtures were unreadable.
- an empty BOOLEAN page reported as out of memory, so an all-null column failed.
- `%zu` in a message format, unsupported by MinGW's C runtime.
- an SSE4.2 guard that MinGW does not legalize without `-msse4.2`.

**Contract violations** — the API promises something it does not do:

- `num_threads = 1` raised to two, so a caller cannot ask for serial work.
- preload and offset-index failures swallowed instead of propagated.

The four optimizations and the API addition are worth offering separately, and
only if upstream wants them; none of them fixes anything.

### Already fixed upstream

Upstream reached v0.7.0_2 while qio was pinned at v0.6.0. A survey of the pin
against `main` on 2026-08-04 found four patches upstream has since fixed
independently:

| Patch | Upstream state |
|---|---|
| Fix scalar Snappy overlap | fixed; `big_pattern` is 16, with the same reasoning |
| Per-thread zstd context on Windows | fixed by a different mechanism, `TlsAlloc` rather than `__declspec(thread)` |
| Decode RLE as a BOOLEAN data encoding | fixed; `decode_phase3_values()` has the case |
| Accept a legal DELTA_BINARY_PACKED block size | fixed; validated against the specification |
| Unpack bit widths 9-32 with a 64-bit accumulator | superseded; `carquet_bitunpack8_general()` was rewritten to gather each value through a 64-bit word with shift/mask, and the `% 8` loop is gone. Whether qio's rolling accumulator still beats it is a benchmark question, not a correctness one |

Do not report these. Retire each patch at the next re-vendor and confirm its
test still passes against the upstream implementation, which is not always the
same code qio wrote.

The rest were still absent from `main`, confirmed by preparing a branch for each
and building it. The memory-unsafe one is the one to report first: upstream's
`decode_phase3_values()` still has no `preserve_dictionary` guard at its entry
while still sizing the value buffer for `uint32_t` indices at three call sites.

`rle.c` changed substantially in v0.7.0. `perf/rle-whole-groups` still applies
cleanly and passes, but whether it is still an improvement over the rewritten
decoder is unmeasured; settle it with a benchmark during the re-vendor.

## Re-vendoring

Upstream carquet moves fast: v0.7.0 rewrote large parts of the reader and writer
and added an Arrow C data interface. Expect conflicts, and expect some patches
to be obsolete.

1. Sync the fork's mirror:

   ```sh
   cd ../carquet
   git fetch upstream
   git checkout main && git merge --ff-only upstream/main && git push origin main
   ```

2. Rebase the series onto the new upstream commit:

   ```sh
   git checkout qio && git rebase <new-upstream-commit>
   ```

   A patch that upstream has fixed will conflict or empty out. Drop it, and
   delete its ledger entry — do not carry a patch upstream already has. A patch
   that conflicts on code upstream merely moved should be reapplied by hand.

3. Push the rebased branch (`git push --force-with-lease origin qio`) and update
   **both** pins and the retrieved date in the table above.

4. Copy the source subsets listed under [Included source](#included-source) into
   `src/carquet/`, and update the license files.

5. Run carquet's own test suite against the rebased series, from the fork:

   ```sh
   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCARQUET_BUILD_TESTS=ON
   cmake --build build -j8 && ctest --test-dir build -j8
   ```

   This is not optional and qio's suite is not a substitute for it. A patch can
   break a carquet code path that no qio call reaches — `482e2cc` is exactly
   that — and every R-level test plus `R CMD check` will stay green while it
   does. The fork's CI runs this on every push; a red `qio` branch blocks
   re-vendoring.

6. Reconcile this ledger with the rebased series: one `###` entry per commit, in
   the same order. `tools/check-vendor-drift.sh` fails if the counts disagree.

7. Clean all native objects, because vendored headers may have changed.

8. Build, run the focused native and interoperability tests, then the complete
   test suite and `R CMD check`.

9. Confirm `tools/check-vendor-drift.sh` passes against the new pins.

10. Dispatch the `native-checks` and `gctorture` workflows: a re-vendor changes
   C that no R-level test exercises directly.
