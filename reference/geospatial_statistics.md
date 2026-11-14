# Inspect Parquet geospatial statistics

Reports the GeospatialStatistics that writers record for `GEOMETRY` and
`GEOGRAPHY` columns: each column chunk's bounding box and the geometry
types it holds. One row per row group and geospatial column, whether or
not the chunk carries them, so a reader can choose row groups by box
before reading any data. qio's own writer records the geometry types for
every geospatial column, and a bounding box for `GEOMETRY`. It records
no box for `GEOGRAPHY`, whose edges are geodesics that a box of the
vertices does not bound, and neither box nor types for a chunk holding a
value it cannot read as WKB.

## Usage

``` r
geospatial_statistics(x, ...)

# S3 method for class 'qio_parquet_file'
geospatial_statistics(x, ...)
```

## Arguments

- x:

  A `qio_parquet_file` object.

- ...:

  Reserved for future use.

## Value

A data frame with one row per row group and geospatial column, ordered
by row group, then column, with the columns:

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
  [`schema()`](https://pedrobtz.github.io/qio/reference/schema.md).

- `xmin`, `xmax`, `ymin`, `ymax`:

  The bounding box, or `NA` when none was recorded.

- `zmin`, `zmax`, `mmin`, `mmax`:

  The Z and M ranges, or `NA` when the geometries have no such dimension
  or none was recorded.

- `geometry_types`:

  A list column of the ISO WKB geometry type codes present (1 for a
  point, 1001 for a point with Z, ...), or `NULL` when none were
  recorded, which Parquet reads as unknown.

## Details

Like
[`column_statistics()`](https://pedrobtz.github.io/qio/reference/column_statistics.md),
the bounds are claims made by whoever wrote the file. An `xmin` greater
than `xmax` means the box wraps the antimeridian.

## See also

[`column_statistics()`](https://pedrobtz.github.io/qio/reference/column_statistics.md),
[`parquet_schema()`](https://pedrobtz.github.io/qio/reference/parquet_schema.md)
for writing geospatial columns.

## Examples

``` r
path <- tempfile(fileext = ".parquet")
point <- function(x, y) {
  c(as.raw(1), writeBin(1L, raw(), size = 4, endian = "little"),
    writeBin(c(x, y), raw(), size = 8, endian = "little"))
}
df <- data.frame(id = 1:2)
df$geom <- list(point(1, 2), point(3, 4))
write_parquet(df, path, schema = parquet_schema(geom = "GEOMETRY"))
pf <- open_parquet(path)
geospatial_statistics(pf)
#>   row_group column path xmin xmax ymin ymax zmin zmax mmin mmax geometry_types
#> 1         1      2 geom    1    3    2    4   NA   NA   NA   NA              1
close_parquet(pf)
```
