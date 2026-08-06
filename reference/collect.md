# Collect data from a Parquet file

Columns are returned in requested order. Row groups are always returned
in their physical file order, even if their selector is not sorted.

## Usage

``` r
collect(x, ...)

# S3 method for class 'qio_parquet_file'
collect(
  x,
  ...,
  columns = NULL,
  row_groups = NULL,
  batch_size = 65536L,
  int64 = c("double", "integer64"),
  time = c("numeric", "hms"),
  tz = "UTC",
  verbose = FALSE
)
```

## Arguments

- x:

  A `qio_parquet_file` object.

- ...:

  Reserved for future use.

- columns:

  Character vector of complete column paths, or `NULL` for all columns.
  Paths are matched exactly as
  [`schema()`](https://pedrobtz.github.io/qio/reference/schema.md) and
  [`names()`](https://rdrr.io/r/base/names.html) report them,
  dot-separated for nested leaves, and never by leaf name alone: two
  leaves may share a name under different parents. An unknown path is an
  error, and so is a path matching more than one leaf.

- row_groups:

  Integer vector of 1-based row-group IDs, or `NULL` for all row groups.

- batch_size:

  Positive number of rows decoded at a time. It bounds the reader's
  scratch memory, not the size of the result (see Details);
  [`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md)
  additionally uses it as the size of each batch.

- int64:

  How 64-bit integer columns reach R. `"double"` (the default) is exact
  from `-2^53` through `2^53` and returns `NA` outside it. `"integer64"`
  returns
  [bit64::integer64](https://bit64.r-lib.org/reference/bit64-package.html),
  which needs the suggested `bit64` package and covers the signed 64-bit
  range **except its lowest value**: `bit64` reserves
  `-9223372036854775808` as its own `NA`, so a column storing
  `INT64_MIN` reads as `NA` in either mode. Either way values that
  cannot be represented become `NA`, and one warning naming the column
  is emitted for each column that lost values – once per column, however
  many values, row groups, or batches were affected, and never for a
  column that lost nothing. Unsigned 64-bit columns are never returned
  as negative numbers.

- time:

  How `TIME` columns reach R: `"numeric"` (the default) returns seconds
  since midnight, `"hms"` returns
  [hms::hms](https://hms.tidyverse.org/reference/hms.html) and needs the
  suggested `hms` package. Neither returns `POSIXct`, because a time of
  day is not an instant.

- tz:

  Time zone name, `"UTC"` by default. A UTC-adjusted `TIMESTAMP` is an
  instant, so `tz` changes only how it prints. A non-UTC `TIMESTAMP` is
  a wall clock with no zone stored, so its civil components are
  interpreted in `tz`; base R decides ambiguous and nonexistent times at
  daylight-saving boundaries. The machine's local zone is never used
  implicitly.

- verbose:

  Report what the read is about to do before doing it: the rows,
  columns, and row groups selected, the batch size, and the resolved
  [`read_plan()`](https://pedrobtz.github.io/qio/reference/read_plan.md)
  for the selected columns only – not for the whole file, so it answers
  "what am I about to get". Written with
  [`message()`](https://rdrr.io/r/base/message.html), so it goes to
  stderr and [`suppressMessages()`](https://rdrr.io/r/base/message.html)
  silences it.

## Value

A data frame.

## Details

`collect()` returns the whole selection, so `batch_size` does not bound
the result; use
[`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md)
for that. It does bound the scratch memory the reader allocates while
decoding string and binary columns, which would otherwise scale with the
largest selected row group rather than with anything the caller
controls. Smaller batches lower peak memory and cost a little throughput
on dictionary-encoded text.

Nested and repeated columns are not materialized in qio 0.1.0. When a
selection includes them, they are omitted and one message reports how
many physical leaf columns were skipped. Nested reading is deferred to
qio 0.2.0. If every selected column is nested, the result is a
zero-column data frame with the selected number of rows.

## See also

[`open_parquet()`](https://pedrobtz.github.io/qio/reference/open_parquet.md)
for the handle and for `mmap` and `threads`,
[`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md)
to process a file that does not fit in memory,
[`read_plan()`](https://pedrobtz.github.io/qio/reference/read_plan.md)
to preview the R type of every column, and
[`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md),
which is
[`open_parquet()`](https://pedrobtz.github.io/qio/reference/open_parquet.md)
plus `collect()` for a whole file.

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(mtcars, path)
pf <- open_parquet(path)
collect(pf, columns = c("mpg", "cyl"))
#>     mpg cyl
#> 1  21.0   6
#> 2  21.0   6
#> 3  22.8   4
#> 4  21.4   6
#> 5  18.7   8
#> 6  18.1   6
#> 7  14.3   8
#> 8  24.4   4
#> 9  22.8   4
#> 10 19.2   6
#> 11 17.8   6
#> 12 16.4   8
#> 13 17.3   8
#> 14 15.2   8
#> 15 10.4   8
#> 16 10.4   8
#> 17 14.7   8
#> 18 32.4   4
#> 19 30.4   4
#> 20 33.9   4
#> 21 21.5   4
#> 22 15.5   8
#> 23 15.2   8
#> 24 13.3   8
#> 25 19.2   8
#> 26 27.3   4
#> 27 26.0   4
#> 28 30.4   4
#> 29 15.8   8
#> 30 19.7   6
#> 31 15.0   8
#> 32 21.4   4
close_parquet(pf)
```
