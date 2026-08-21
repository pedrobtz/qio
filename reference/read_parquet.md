# Read a Parquet file

Reads an Apache Parquet file into a data frame.

## Usage

``` r
read_parquet(
  file,
  ...,
  columns = NULL,
  row_groups = NULL,
  int64 = c("double", "integer64"),
  time = c("numeric", "hms"),
  tz = "UTC",
  verbose = FALSE
)
```

## Arguments

- file:

  Path to a Parquet file, or an `http://`, `https://`, `ftp://`,
  `ftps://` or `file://` URL. A URL is downloaded to the session
  temporary directory in full before any of it is read, and the copy is
  removed when the read finishes; see
  [qio-limitations](https://pedrobtz.github.io/qio/reference/qio-limitations.md).

- ...:

  Must be empty. Every argument after it is name-only, matching
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md),
  [`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md)
  and
  [`read_plan()`](https://pedrobtz.github.io/qio/reference/read_plan.md),
  which take the same arguments the same way.

- columns:

  Character vector of complete column paths, or `NULL` (the default) for
  all columns; see
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md).

- row_groups:

  Integer vector of 1-based row-group IDs, or `NULL` (the default) for
  all row groups.

- int64:

  How 64-bit integer columns reach R; see
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md).

- time:

  How `TIME` columns reach R; see
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md).

- tz:

  Time zone for `TIMESTAMP` columns; see
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md).

- verbose:

  Report the read plan before reading; see
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md).

## Value

A data frame.

## Details

Column types are mapped from Parquet as follows: `BOOLEAN` to logical,
`INT32` to integer, and `INT64`/`FLOAT`/`DOUBLE` to double. A
`BYTE_ARRAY` becomes character only when the file annotates it `STRING`,
`ENUM`, or `JSON`; without an annotation it is arbitrary bytes and is
returned as a list of raw vectors, because assuming UTF-8 the file never
claimed would corrupt binary data. An `INT32` column annotated `DATE` is
returned as a `Date`, a UTC-adjusted `TIMESTAMP` (physical `INT64`) as a
`POSIXct` in UTC, and a legacy `INT96` timestamp as a `POSIXct` in UTC
(interpreting its Julian-day and nanosecond-of-day parts as an instant).
Parquet nulls become `NA`. `INT64` values are returned as doubles and
lose precision beyond 2^53, which for microsecond and nanosecond
timestamps can drop sub-second precision far from the epoch. Use
[`read_plan()`](https://pedrobtz.github.io/qio/reference/read_plan.md)
to preview the R type of each column before reading.

Nested and repeated columns are skipped with one message. Nested reading
is deferred to qio 0.2.0.

The file is memory-mapped for the duration of the read (falling back to
buffered reads if mapping fails) so columns decode in parallel; the
mapping is released before the function returns.

`columns` and `row_groups` read part of a file and are passed straight
to [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md).
Selecting columns is the single largest speedup available on a wide
file, because a column that is not selected is never decompressed. Use
[`open_parquet()`](https://pedrobtz.github.io/qio/reference/open_parquet.md)
with [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md)
for the rest: `batch_size`, `mmap`, `threads`, and `verify_checksums`.

## See also

[`write_parquet()`](https://pedrobtz.github.io/qio/reference/write_parquet.md),
[`open_parquet()`](https://pedrobtz.github.io/qio/reference/open_parquet.md)
and [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md)
to read part of a file,
[`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md)
for a file larger than memory, and
[`read_plan()`](https://pedrobtz.github.io/qio/reference/read_plan.md)
to preview the R type of every column before reading.

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(data.frame(x = 1:3, y = c("a", "b", NA)), path)
read_parquet(path)
#>   x    y
#> 1 1    a
#> 2 2    b
#> 3 3 <NA>
```
