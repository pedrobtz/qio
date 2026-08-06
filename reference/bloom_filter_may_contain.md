# Test values against a Parquet bloom filter

A bloom filter answers one question: is this value *definitely absent*
from the column chunk? It never proves presence. `FALSE` means the value
is not there; `TRUE` means it may be, and only reading can settle it.

## Usage

``` r
bloom_filter_may_contain(x, column, values, row_group = 1L, ...)

# S3 method for class 'qio_parquet_file'
bloom_filter_may_contain(x, column, values, row_group = 1L, ...)
```

## Arguments

- x:

  A `qio_parquet_file` object.

- column:

  A single complete column path, as
  [`schema()`](https://pedrobtz.github.io/qio/reference/schema.md)
  reports it in `path` and
  [`names()`](https://rdrr.io/r/base/names.html) returns it – not the
  bare `name`, which is not unique across a nested file.

- values:

  Values to test. Numeric for numeric columns, character for byte-array
  columns. `NA` returns `NA`.

- row_group:

  Row group to test, 1-based. A bloom filter belongs to one column
  chunk, so it covers one row group.

- ...:

  Reserved for future use.

## Value

A logical vector the length of `values`: `FALSE` where the value is
definitely absent, `TRUE` where it may be present.

## Details

Values are matched against the column's physical type, because that is
what the writer hashed. A value qio cannot reduce to that type is an
error rather than a `FALSE`, which would read as "definitely absent".

qio's own writer does not emit bloom filters; see
[qio-limitations](https://pedrobtz.github.io/qio/reference/qio-limitations.md).
Use
[`column_chunks()`](https://pedrobtz.github.io/qio/reference/column_chunks.md)
to find out whether a chunk has one.

## See also

[`column_chunks()`](https://pedrobtz.github.io/qio/reference/column_chunks.md)
