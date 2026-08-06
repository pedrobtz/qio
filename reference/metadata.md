# Inspect Parquet footer metadata

Duplicate keys are preserved in their original order.

## Usage

``` r
metadata(x, ...)

# S3 method for class 'qio_parquet_file'
metadata(x, ...)
```

## Arguments

- x:

  A `qio_parquet_file` object.

- ...:

  Reserved for future use.

## Value

A data frame with `key` and `value` columns.

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(mtcars, path)
pf <- open_parquet(path)
metadata(pf)
#> [1] key   value
#> <0 rows> (or 0-length row.names)
close_parquet(pf)
```
