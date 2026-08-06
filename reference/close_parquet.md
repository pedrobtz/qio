# Close a Parquet file

Explicitly releases the native resources owned by an open Parquet
handle. Closing an already closed handle has no effect.

## Usage

``` r
close_parquet(x)
```

## Arguments

- x:

  A `qio_parquet_file` object.

## Value

`x`, invisibly.

## See also

[`open_parquet()`](https://pedrobtz.github.io/qio/reference/open_parquet.md)

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(mtcars, path)
pf <- open_parquet(path)
close_parquet(pf)
```
