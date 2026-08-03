# Public API review

The public API is structurally coherent, but the package is not release-ready
yet. Three issues are blockers; several naming and documentation
inconsistencies are best fixed before the first release.

## Findings

### High: INT64 coercion writes beyond a one-byte flag

`qio_scatter_int64()` accepts `int *coerced` and writes four bytes, but callers
pass a `uint8_t *` allocated as one byte per column. This can corrupt adjacent
flags or memory whenever an INT64 value is coerced to `NA`. The compiler
correctly warns about it during R CMD check.

See `src/qio_file.c:642`, `src/qio_file.c:909`, and `src/qio_file.c:1568`.

### High: unequal list columns are silently recycled when writing

The API documents lists of equal-length vectors, but `qio_as_data_frame()`
delegates directly to `as.data.frame()`. For example,
`list(a = 1:4, b = 10:11)` writes four rows with `b` silently recycled to
`10, 11, 10, 11`.

This is silent data transformation and should be rejected explicitly before
conversion. See `R/parquet-schema.R:190` and the documented contract in
`R/parquet.R:119`.

### High: `collect()` does not interoperate with dplyr's generic

qio defines its own `collect()` generic. In a session where dplyr masks it,
both `collect(pf)` and `dplyr::collect(pf)` fail with "no applicable method."
This was reproduced with dplyr 1.2.1.

Consider dynamically registering `collect.qio_parquet_file` with dplyr's
generic while retaining zero required dependencies, or provide an unambiguous
primary function such as `collect_parquet()`.

See `R/parquet-file.R:213`. This is amplified by the README, which uses
unqualified `schema()`, `row_groups()`, and `collect()` after only calling
`qio::open_parquet()`. That example fails even in a clean session unless qio is
attached; see `README.md:48`.

### Medium: the exported type summary reports the wrong `BYTE_ARRAY` mapping

`parquet_type_mapping()` reports bare `BYTE_ARRAY` as `character`, although
actual reads and `read_plan()` correctly return a list of raw vectors unless
the file has a text annotation.

The stale registry value is at `R/parquet-plan.R:25`; the implemented binary
rule is at `R/parquet-plan.R:223`. The main `read_parquet()` help repeats the
obsolete "assumed UTF-8" behavior at `R/parquet.R:5`.

### Medium: several help topics contradict behavior

- `walk_batches()` forwards `...` to `FUN`, but its generated help says `...`
  is "Reserved for future use," caused by inheriting `collect()` parameters;
  see `man/walk_batches.Rd:26`.
- The help claims `bit64::integer64` covers the full signed range, but
  `INT64_MIN` is bit64's reserved missing-value sentinel and becomes `NA`; the
  tests demonstrate this at `tests/testthat/test-external.R:343`.
- `read_plan()` documentation lists only a small subset of the logical
  conversions now implemented; see `R/parquet-plan.R:376`.

### Medium: public result-column names and path semantics are inconsistent

The same concepts currently use several names:

- `physical_type` in `schema()`, `type` in `column_chunks()`, and
  `parquet_type` in `parquet_type_mapping()`;
- `r_type` in `read_plan()` versus `read_as` in
  `parquet_type_mapping()`;
- `repetition` in a read schema versus `repetition_type` in a writer schema;
  and
- `schema()$name` is a leaf name, while `column_chunks()$name` is actually the
  complete path.

Relatedly, `bloom_filter_may_contain()` documents a "column name, as schema
reports it," but matches against `names(x)`, meaning the complete path; see
`R/parquet-file.R:783`.

The `schema()` help only says that it returns a data frame and does not
document its ten result columns or the crucial `name`/`path` distinction; see
`R/parquet-file.R:72`.

### Medium: writer validation is inconsistent

- `row_group_size = 1.9` is silently floored to `1`, whereas fractional
  `batch_size` and `threads` are rejected. Row counts should consistently
  require whole numbers; see `R/parquet.R:196`.
- Duplicate data-frame names are accepted when no explicit schema is supplied.
  qio can write such a file and read all columns, but selective
  `collect(columns = "dup")` then fails as ambiguous. Unique names are checked
  only in the explicit-schema branch; see `R/parquet-schema.R:254`.

### Low: release version references disagree

`DESCRIPTION` is version `0.0.1`, `NEWS.md` is headed `0.0.0.9000`, and public
help repeatedly describes behavior as "qio 0.1.0." These should be aligned
before publishing; see `DESCRIPTION:3` and `NEWS.md:1`.

## What is already consistent

The central read defaults are well aligned:

- `int64 = "double"`;
- `time = "numeric"`;
- `tz = "UTC"`;
- `columns = NULL`;
- `row_groups = NULL`;
- `batch_size = 65536L` for `collect()` and `walk_batches()`; and
- `verbose = FALSE`.

The `file` versus handle argument convention is also clear: paths use `file`,
open handles use `x`. Singular and plural selector names are sensible. The
different `mmap` defaults for eager and persistent reads are documented and
justified.

## Validation performed

- Full tests: 944 passed, with no failures, warnings, or skips.
- Reference index: all 20 exported and help topics are indexed.
- `pkgdown::check_pkgdown()`: passed.
- R CMD check: 0 errors, 1 warning, and 0 notes. The warning is the unsafe
  INT64 pointer mismatch above.

