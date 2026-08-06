# Inspect Parquet column statistics

Reports the per-column, per-row-group statistics recorded in the file:
value and null counts, and the minimum and maximum bounds.

## Usage

``` r
column_statistics(x, ...)

# S3 method for class 'qio_parquet_file'
column_statistics(x, ...)
```

## Arguments

- x:

  A `qio_parquet_file` object.

- ...:

  Reserved for future use.

## Value

A data frame with one row per column chunk, ordered by row group and
then by column, with the columns:

- `row_group`:

  1-based row-group ID, as
  [`row_groups()`](https://pedrobtz.github.io/qio/reference/row_groups.md)
  reports it.

- `column`:

  1-based physical column index, as
  [`schema()`](https://pedrobtz.github.io/qio/reference/schema.md)
  reports it.

- `path`:

  Complete dotted column path; see
  [`schema()`](https://pedrobtz.github.io/qio/reference/schema.md).

- `num_values`:

  Values the statistics cover, nulls included.

- `null_count`:

  Nulls the writer recorded, or `NA` when it recorded none. `NA` means
  unknown, not zero.

- `distinct_count`:

  Distinct values the writer recorded, or `NA`. Most writers omit it, so
  `NA` is the common case.

- `min`, `max`:

  List columns of physical-level bounds, one element per row; `NULL`
  when absent or undecodable. See Details.

Counts are doubles rather than integers, because a chunk can hold more
values than `.Machine$integer.max`.

## Details

These are **claims made by whoever wrote the file**, not facts qio
verifies. A reader that skips a row group on them is trusting that
writer. qio does not use them to skip anything.

`min` and `max` are list columns, because one file can hold columns of
different types. Each element holds the bound decoded at the *physical*
level: an `INT64` bound stays a number rather than becoming a `POSIXct`,
and a decimal is not scaled, since a bound is a sort key rather than a
value to compute with. Text columns are the exception and decode to
character. An element is `NULL` when the bound is absent, or is present
but the wrong width for its type.

## See also

[`column_chunks()`](https://pedrobtz.github.io/qio/reference/column_chunks.md),
[`row_groups()`](https://pedrobtz.github.io/qio/reference/row_groups.md)

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(data.frame(n = 1:100), path, row_group_size = 25)
pf <- open_parquet(path)
stats <- column_statistics(pf)
stats[c("row_group", "path", "null_count")]
#>   row_group path null_count
#> 1         1    n          0
#> 2         2    n          0
#> 3         3    n          0
#> 4         4    n          0
unlist(stats$min)
#> [1]  1 26 51 76
close_parquet(pf)
```
