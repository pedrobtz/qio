# Find the null rows of a struct column

qio reads a Parquet struct as a data-frame column. A null struct and a
struct whose fields are all null both have `NA` in every field, so an
optional struct carries which rows are null itself. `is_null_struct()`
returns that.

## Usage

``` r
is_null_struct(x)
```

## Arguments

- x:

  A data-frame column that
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md) or
  [`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md)
  returned for a Parquet struct, or any data frame.

## Value

A logical vector with one value per row of `x`: `TRUE` where the struct
is null. A required struct, or any data frame qio did not make, is never
null, so the result is all `FALSE`.

Row subsetting (`x[i, ]`, and subsetting the data frame holding `x`)
keeps the mask in step. Combining rows with
[`rbind()`](https://rdrr.io/r/base/cbind.html) does not, and
`is_null_struct()` then refuses rather than guess.

## See also

The "Nested columns" section of
[`collect()`](https://pedrobtz.github.io/qio/reference/collect.md).

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(data.frame(x = 1:3), path)
is_null_struct(read_parquet(path))
#> [1] FALSE FALSE FALSE
```
