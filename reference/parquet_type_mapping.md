# Show Parquet physical type mappings

Lists every Parquet physical type and the R storage type qio uses for it
**when the column carries no logical annotation**. Missing values
indicate unsupported mappings.

## Usage

``` r
parquet_type_mapping()
```

## Value

A data frame with one row per Parquet physical type and the columns:

- `physical_type`:

  Parquet physical type, spelled as
  [`schema()`](https://pedrobtz.github.io/qio/reference/schema.md) and
  [`read_plan()`](https://pedrobtz.github.io/qio/reference/read_plan.md)
  report it.

- `r_type`:

  R type produced with no logical annotation, spelled as
  [`read_plan()`](https://pedrobtz.github.io/qio/reference/read_plan.md)
  reports it. `NA` when the type cannot be read.

- `written_from`:

  R input that infers this physical type, or `NA` when
  [`write_parquet()`](https://pedrobtz.github.io/qio/reference/write_parquet.md)
  cannot produce it.

## Details

These are physical fallbacks, and most real columns are annotated, so
this table is not a prediction of what a given file will produce. Use
[`read_plan()`](https://pedrobtz.github.io/qio/reference/read_plan.md)
for that: it resolves the annotation, the `int64`, `time`, and `tz`
options, and reports the R type each column will actually materialize
as.

Two entries are worth reading carefully. `BYTE_ARRAY` and
`FIXED_LEN_BYTE_ARRAY` are bytes here, returned as a list of raw
vectors, because bytes are only text when the file says so; a `STRING`,
`ENUM`, or `JSON` annotation is what makes a `BYTE_ARRAY` character.
`INT96` is a deprecated physical type used only for timestamps, so it is
read as `POSIXct` with no annotation involved.

## See also

[`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md),
[`write_parquet()`](https://pedrobtz.github.io/qio/reference/write_parquet.md),
[`schema()`](https://pedrobtz.github.io/qio/reference/schema.md)

## Examples

``` r
parquet_type_mapping()
#>          physical_type  r_type              written_from
#> 1              BOOLEAN logical                   logical
#> 2                INT32 integer                   integer
#> 3                INT64  double numeric (explicit schema)
#> 4                INT96 POSIXct                      <NA>
#> 5                FLOAT  double numeric (explicit schema)
#> 6               DOUBLE  double                    double
#> 7           BYTE_ARRAY    list       character or factor
#> 8 FIXED_LEN_BYTE_ARRAY    list                      <NA>
```
