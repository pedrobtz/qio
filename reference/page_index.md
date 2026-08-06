# Inspect Parquet page indexes

Reports the per-page index of each column chunk: where each data page
sits in the file, which row it starts at, and the bounds and null count
it declares. One row per page.

## Usage

``` r
page_index(x, ...)

# S3 method for class 'qio_parquet_file'
page_index(x, ...)
```

## Arguments

- x:

  A `qio_parquet_file` object.

- ...:

  Reserved for future use.

## Value

A data frame with one row per page, ordered by row group, then column,
then page, with the columns:

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

- `page`:

  1-based page number within this column chunk, restarting at 1 for
  every chunk.

- `first_row`:

  0-based row within the row group where the page starts. The first page
  of a chunk is 0.

- `offset`:

  Byte offset of the page from the start of the file.

- `compressed_bytes`:

  Size of the page on disk.

- `null_count`:

  Nulls on the page, or `NA` when not recorded.

- `null_page`:

  Whether the page holds only nulls, in which case its bounds carry no
  information.

- `min`, `max`:

  List columns of physical-level bounds, decoded as in
  [`column_statistics()`](https://pedrobtz.github.io/qio/reference/column_statistics.md);
  `NULL` when absent.

The two indexes are independent and either may be missing. `first_row`,
`offset`, and `compressed_bytes` come from the offset index and are `NA`
without it; `null_count`, `null_page`, `min`, and `max` come from the
column index and are `NA` or `NULL` without it.

## Details

A page index is optional, and many writers omit it. Columns without one
contribute no rows, so a file with no page index at all returns a
zero-row data frame rather than an error. qio's own writer does not emit
page indexes; see
[qio-limitations](https://pedrobtz.github.io/qio/reference/qio-limitations.md).

Like
[`column_statistics()`](https://pedrobtz.github.io/qio/reference/column_statistics.md),
the bounds are claims made by whoever wrote the file. qio reports them
and does not use them to skip pages.

## See also

[`column_statistics()`](https://pedrobtz.github.io/qio/reference/column_statistics.md),
[`column_chunks()`](https://pedrobtz.github.io/qio/reference/column_chunks.md)

## Examples

``` r
# qio does not write page indexes, so a file it wrote has none and the
# result is empty rather than an error.
path <- tempfile(fileext = ".parquet")
write_parquet(data.frame(n = 1:10), path)
pf <- open_parquet(path)
nrow(page_index(pf))
#> [1] 0
close_parquet(pf)
```
