# Infer the Parquet writer schema for an R object

Shows the physical and logical Parquet types that
[`write_parquet()`](https://pedrobtz.github.io/qio/reference/write_parquet.md)
would use without an explicit schema. Nullability is inferred from
missing values.

## Usage

``` r
infer_parquet_schema(x)
```

## Arguments

- x:

  A data frame or list of equal-length atomic vectors.

## Value

A `qio_parquet_schema` data frame with one row per column.

## Examples

``` r
infer_parquet_schema(data.frame(id = 1:3, when = as.Date("2020-01-01")))
#> <qio_parquet_schema: 2 columns>
#>   name physical_type logical_type logical_details repetition_type
#> 1   id         INT32         <NA>            <NA>        REQUIRED
#> 2 when         INT32         DATE            <NA>        REQUIRED
```
