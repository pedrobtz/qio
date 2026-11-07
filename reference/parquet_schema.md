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
`"FLOAT"`, `"DOUBLE"`, `"STRING"`, `"DATE"`, `"TIMESTAMP"`, `"BINARY"`,
`"GEOMETRY"`, and `"GEOGRAPHY"`. `TIMESTAMP` accepts `unit` (`"MILLIS"`,
`"MICROS"`, or `"NANOS"`) and must be adjusted to UTC. All types accept
`repetition_type` (`"AUTO"`, `"REQUIRED"`, or `"OPTIONAL"`).

`INT32` and `INT64` declarations accept finite whole-number inputs;
`INT64` is limited to R's exact double-integer range from `-2^53`
through `2^53`. `FLOAT` and `DOUBLE` accept numeric input, `STRING`
accepts character or factor input, `DATE` accepts `Date` or whole-number
days, and `TIMESTAMP` accepts `POSIXct`.

`"BINARY"`, `"GEOMETRY"` and `"GEOGRAPHY"` take a list of raw vectors,
with `NULL` for a missing value; such a list is written as `BINARY`
without a schema. `GEOMETRY` and `GEOGRAPHY` hold well-known binary
(WKB) and accept `crs`, a string of at most 127 bytes such as
`"OGC:CRS84"` (the default), `"EPSG:4326"`, or `"projjson:<key>"` naming
a footer
[`write_parquet()`](https://pedrobtz.github.io/qio/reference/write_parquet.md)
`metadata` entry that holds the PROJJSON. `GEOGRAPHY` also accepts
`algorithm`, the edge interpolation: `"SPHERICAL"` (the default),
`"VINCENTY"`, `"THOMAS"`, `"ANDOYER"`, or `"KARNEY"`. qio does not parse
the WKB beyond what
[`geospatial_statistics()`](https://pedrobtz.github.io/qio/reference/geospatial_statistics.md)
records.

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
parquet_schema(
  shape = list("GEOMETRY", crs = "EPSG:4326"),
  route = list("GEOGRAPHY", algorithm = "KARNEY")
)
#> <qio_parquet_schema: 2 columns>
#>    name physical_type logical_type                 logical_details
#> 1 shape    BYTE_ARRAY     GEOMETRY                   crs=EPSG:4326
#> 2 route    BYTE_ARRAY    GEOGRAPHY crs=OGC:CRS84, algorithm=KARNEY
#>   repetition_type
#> 1            AUTO
#> 2            AUTO
```
