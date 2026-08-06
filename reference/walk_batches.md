# Walk over batches from a Parquet file

Calls `FUN(batch, index, ...)` for every batch. Each batch is an
independent data frame and can be retained by the callback when desired.
Callback return values are discarded.

## Usage

``` r
walk_batches(
  x,
  FUN,
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

- FUN:

  Function called with a data frame and a 1-based global batch index,
  followed by `...`.

- ...:

  Passed on to `FUN` after the batch and its index. This differs from
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md),
  where `...` must be empty: here it is how a callback receives extra
  arguments. Every argument after it is still name-only.

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

  Positive number of rows decoded per batch.

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

`x`, invisibly.

## See also

[`collect()`](https://pedrobtz.github.io/qio/reference/collect.md) for
the same selection returned as one data frame, and
[`open_parquet()`](https://pedrobtz.github.io/qio/reference/open_parquet.md)
for the handle.

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(mtcars, path)
pf <- open_parquet(path)
walk_batches(pf, function(batch, index) print(head(batch)))
#>    mpg cyl disp  hp drat    wt  qsec vs am gear carb
#> 1 21.0   6  160 110 3.90 2.620 16.46  0  1    4    4
#> 2 21.0   6  160 110 3.90 2.875 17.02  0  1    4    4
#> 3 22.8   4  108  93 3.85 2.320 18.61  1  1    4    1
#> 4 21.4   6  258 110 3.08 3.215 19.44  1  0    3    1
#> 5 18.7   8  360 175 3.15 3.440 17.02  0  0    3    2
#> 6 18.1   6  225 105 2.76 3.460 20.22  1  0    3    1
close_parquet(pf)
```
