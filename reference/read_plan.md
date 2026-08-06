# Plan how a Parquet file is read into R

Builds a read plan from a Parquet schema: one row per physical leaf
column describing the R type each column will materialize as, whether it
can be collected, and why not when it cannot. The plan is a pure
function of the schema, so it is cheap to compute and inspect before
reading any data.

## Usage

``` r
read_plan(x, ...)

# S3 method for class 'qio_parquet_file'
read_plan(
  x,
  ...,
  int64 = c("double", "integer64"),
  time = c("numeric", "hms"),
  tz = "UTC"
)

# S3 method for class 'character'
read_plan(
  x,
  ...,
  int64 = c("double", "integer64"),
  time = c("numeric", "hms"),
  tz = "UTC"
)

# S3 method for class 'data.frame'
read_plan(
  x,
  ...,
  int64 = c("double", "integer64"),
  time = c("numeric", "hms"),
  tz = "UTC"
)
```

## Arguments

- x:

  A Parquet file path, a `qio_parquet_file` object, or the data frame
  returned by
  [`schema()`](https://pedrobtz.github.io/qio/reference/schema.md).

- ...:

  Reserved for future use.

- int64:

  How 64-bit integer columns reach R; see
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md).
  The plan reports the resulting `r_type` and `converter`, so it can be
  inspected for exactly the read that will follow.

- time:

  How `TIME` columns reach R; see
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md).

- tz:

  Time zone for `TIMESTAMP` columns; see
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md).

## Value

A `qio_read_plan` data frame with one row per physical leaf column and
the columns:

- `column`:

  1-based physical column index.

- `name`, `path`:

  Column name and dotted path.

- `physical_type`, `logical_type`:

  Parquet physical type and logical annotation (`NA` when absent).

- `r_type`:

  Target R type, or `NA` when the column cannot be collected.

- `converter`:

  Stable identifier of the conversion the reader uses.

- `nullable`:

  Whether the column can contain nulls.

- `nested`:

  Whether the leaf belongs to a nested or repeated field.

- `collectible`:

  Whether
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md) can
  currently materialize the column.

- `note`:

  Reason a column is not collectible, or a pending logical annotation;
  `NA` otherwise.

## Details

The plan reflects what
[`collect()`](https://pedrobtz.github.io/qio/reference/collect.md),
[`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md),
and
[`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md)
actually do today. A logical annotation overrides the physical fallback
in
[`parquet_type_mapping()`](https://pedrobtz.github.io/qio/reference/parquet_type_mapping.md),
and the annotations qio resolves are:

- `DATE` to `Date`, and legacy physical `INT96` to `POSIXct`.

- `TIMESTAMP` to `POSIXct`, UTC-adjusted or interpreted in `tz`.

- `TIME` to seconds or
  [hms::hms](https://hms.tidyverse.org/reference/hms.html), selected by
  `time`.

- `INTEGER` at any width and sign, including unsigned 64-bit, which with
  `INT64` is selected by `int64`.

- `STRING`, `ENUM`, and `JSON` to character; everything else stored as
  bytes stays a list of raw vectors.

- `UUID` to canonical text and `FLOAT16` to double.

- `DECIMAL` to double with the scale applied, from either integer or
  binary storage.

Unimplemented annotations are reported in `note` and retain their
physical fallback type. `converter` names the exact conversion the
reader will run, so it distinguishes cases that share an `r_type`.

A path is enough – `read_plan()` opens the file, reads the footer, and
closes it again, so no handle is needed to inspect a file before reading
it. Passing an open
[`open_parquet()`](https://pedrobtz.github.io/qio/reference/open_parquet.md)
handle, or the data frame from
[`schema()`](https://pedrobtz.github.io/qio/reference/schema.md),
produces exactly the same plan; use those when a handle is already open
or when the schema has already been fetched.

Pass the same `int64`, `time`, and `tz` the read will use. The plan
resolves them, so `r_type` and `converter` describe that read rather
than a default one.

## See also

[`schema()`](https://pedrobtz.github.io/qio/reference/schema.md),
[`collect()`](https://pedrobtz.github.io/qio/reference/collect.md),
[`parquet_type_mapping()`](https://pedrobtz.github.io/qio/reference/parquet_type_mapping.md)

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(data.frame(x = 1:3, y = c("a", "b", NA)), path)

# A path is enough; no handle is needed.
read_plan(path)
#> <qio_read_plan: 2 columns, 2 collectible>
#>   column name path physical_type logical_type    r_type converter nullable
#> 1      1    x    x         INT32         <NA>   integer     int32    FALSE
#> 2      2    y    y    BYTE_ARRAY       STRING character      text     TRUE
#>   nested collectible note
#> 1  FALSE        TRUE <NA>
#> 2  FALSE        TRUE <NA>

# The plan answers for the read you are about to do, not a default one.
read_plan(path, int64 = "integer64")
#> <qio_read_plan: 2 columns, 2 collectible>
#>   column name path physical_type logical_type    r_type converter nullable
#> 1      1    x    x         INT32         <NA>   integer     int32    FALSE
#> 2      2    y    y    BYTE_ARRAY       STRING character      text     TRUE
#>   nested collectible note
#> 1  FALSE        TRUE <NA>
#> 2  FALSE        TRUE <NA>

# An open handle and a schema() data frame give the same plan.
pf <- open_parquet(path)
identical(read_plan(pf), read_plan(path))
#> [1] TRUE
close_parquet(pf)
```
