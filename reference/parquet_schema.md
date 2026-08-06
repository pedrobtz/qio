# Create a Parquet writer schema

Creates a reusable schema that controls how
[`write_parquet()`](https://pedrobtz.github.io/qio/reference/write_parquet.md)
stores selected columns. Each argument must be named and may be a type
string or a list whose first element is the type. Schemas may be
partial: unspecified columns keep qio's automatic mapping.

## Usage

``` r
parquet_schema(...)
```

## Arguments

- ...:

  Named Parquet type specifications.

## Value

A `qio_parquet_schema` data frame.

## Details

Supported declarations are `"AUTO"`, `"BOOLEAN"`, `"INT32"`, `"INT64"`,
`"FLOAT"`, `"DOUBLE"`, `"STRING"`, `"DATE"`, and `"TIMESTAMP"`.
`TIMESTAMP` accepts `unit` (`"MILLIS"`, `"MICROS"`, or `"NANOS"`) and
must be adjusted to UTC. All types accept `repetition_type` (`"AUTO"`,
`"REQUIRED"`, or `"OPTIONAL"`).

`INT32` and `INT64` declarations accept finite whole-number inputs;
`INT64` is limited to R's exact double-integer range from `-2^53`
through `2^53`. `FLOAT` and `DOUBLE` accept numeric input, `STRING`
accepts character or factor input, `DATE` accepts `Date` or whole-number
days, and `TIMESTAMP` accepts `POSIXct`.

## Examples

``` r
parquet_schema(
  id = "INT64",
  price = "FLOAT",
  created_at = list("TIMESTAMP", unit = "MILLIS")
)
#> <qio_parquet_schema: 3 columns>
#>         name physical_type logical_type                   logical_details
#> 1         id         INT64         <NA>                              <NA>
#> 2      price         FLOAT         <NA>                              <NA>
#> 3 created_at         INT64    TIMESTAMP unit=MILLIS, adjusted_to_utc=true
#>   repetition_type
#> 1            AUTO
#> 2            AUTO
#> 3            AUTO
```
