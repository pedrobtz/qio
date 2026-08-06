# Inspect Parquet row groups

Inspect Parquet row groups

## Usage

``` r
row_groups(x, ...)

# S3 method for class 'qio_parquet_file'
row_groups(x, ...)
```

## Arguments

- x:

  A `qio_parquet_file` object.

- ...:

  Reserved for future use.

## Value

A data frame with one row per row group and the columns:

- `row_group`:

  1-based row-group ID, which is what `row_groups =` selects on in
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md),
  [`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md),
  and
  [`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md).

- `rows`:

  Rows in the group.

- `compressed_bytes`, `uncompressed_bytes`:

  Total size of the group's column chunks on disk and after
  decompression.

Counts and sizes are doubles rather than integers, because a row group
can exceed `.Machine$integer.max`.

## See also

[`column_chunks()`](https://pedrobtz.github.io/qio/reference/column_chunks.md)
for the same sizes per column, and
[`column_statistics()`](https://pedrobtz.github.io/qio/reference/column_statistics.md)
for what the writer claims about each chunk.

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(mtcars, path)
pf <- open_parquet(path)
row_groups(pf)
#>   row_group rows compressed_bytes uncompressed_bytes
#> 1         1   32             1805               1805
close_parquet(pf)
```
