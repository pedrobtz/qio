# Inspect Parquet column chunks

Reports how each column is stored in each row group: its physical type,
compression, sizes, encodings, and which optional structures are
present. One row per column per row group.

## Usage

``` r
column_chunks(x, ...)

# S3 method for class 'qio_parquet_file'
column_chunks(x, ...)
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
  [`schema()`](https://pedrobtz.github.io/qio/reference/schema.md) for
  why this is the identifier rather than the bare leaf name.

- `physical_type`:

  Parquet physical type of the leaf.

- `compression`:

  Codec name, such as `"SNAPPY"` or `"UNCOMPRESSED"`. Set per chunk, so
  one file may mix codecs.

- `num_values`:

  Values stored in the chunk, nulls included.

- `compressed_bytes`, `uncompressed_bytes`:

  Size of the chunk on disk and after decompression. Equal for an
  uncompressed chunk.

- `encodings`:

  Encodings the chunk declares, comma separated. A dictionary-encoded
  chunk typically lists `RLE_DICTIONARY` alongside the `PLAIN` its
  dictionary page uses.

- `dictionary_page`:

  Whether the chunk has a dictionary page.

- `bloom_filter`:

  Whether a bloom filter is present, which is what
  [`bloom_filter_may_contain()`](https://pedrobtz.github.io/qio/reference/bloom_filter_may_contain.md)
  needs.

- `page_index`:

  Whether a column index or an offset index is present;
  [`page_index()`](https://pedrobtz.github.io/qio/reference/page_index.md)
  reports either.

Sizes and counts are doubles rather than integers, because a chunk can
exceed `.Machine$integer.max`.

## See also

[`column_statistics()`](https://pedrobtz.github.io/qio/reference/column_statistics.md),
[`row_groups()`](https://pedrobtz.github.io/qio/reference/row_groups.md)

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(mtcars, path, row_group_size = 16)
pf <- open_parquet(path)
column_chunks(pf)
#>    row_group column path physical_type compression num_values compressed_bytes
#> 1          1      1  mpg        DOUBLE      SNAPPY         16              129
#> 2          1      2  cyl        DOUBLE      SNAPPY         16               90
#> 3          1      3 disp        DOUBLE      SNAPPY         16              129
#> 4          1      4   hp        DOUBLE      SNAPPY         16              107
#> 5          1      5 drat        DOUBLE      SNAPPY         16              169
#> 6          1      6   wt        DOUBLE      SNAPPY         16              174
#> 7          1      7 qsec        DOUBLE      SNAPPY         16              168
#> 8          1      8   vs        DOUBLE      SNAPPY         16               85
#> 9          1      9   am        DOUBLE      SNAPPY         16               82
#> 10         1     10 gear        DOUBLE      SNAPPY         16               87
#> 11         1     11 carb        DOUBLE      SNAPPY         16               91
#> 12         2      1  mpg        DOUBLE      SNAPPY         16              124
#> 13         2      2  cyl        DOUBLE      SNAPPY         16               90
#> 14         2      3 disp        DOUBLE      SNAPPY         16              119
#> 15         2      4   hp        DOUBLE      SNAPPY         16              107
#> 16         2      5 drat        DOUBLE      SNAPPY         16              181
#> 17         2      6   wt        DOUBLE      SNAPPY         16              181
#> 18         2      7 qsec        DOUBLE      SNAPPY         16              162
#> 19         2      8   vs        DOUBLE      SNAPPY         16               88
#> 20         2      9   am        DOUBLE      SNAPPY         16               85
#> 21         2     10 gear        DOUBLE      SNAPPY         16               89
#> 22         2     11 carb        DOUBLE      SNAPPY         16               89
#>    uncompressed_bytes              encodings dictionary_page bloom_filter
#> 1                 128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 2                 128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 3                 128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 4                 128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 5                 128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 6                 128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 7                 128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 8                 128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 9                 128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 10                128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 11                128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 12                128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 13                128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 14                128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 15                128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 16                128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 17                128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 18                128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 19                128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 20                128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 21                128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#> 22                128 BYTE_STREAM_SPLIT, RLE           FALSE        FALSE
#>    page_index
#> 1       FALSE
#> 2       FALSE
#> 3       FALSE
#> 4       FALSE
#> 5       FALSE
#> 6       FALSE
#> 7       FALSE
#> 8       FALSE
#> 9       FALSE
#> 10      FALSE
#> 11      FALSE
#> 12      FALSE
#> 13      FALSE
#> 14      FALSE
#> 15      FALSE
#> 16      FALSE
#> 17      FALSE
#> 18      FALSE
#> 19      FALSE
#> 20      FALSE
#> 21      FALSE
#> 22      FALSE
close_parquet(pf)
```
