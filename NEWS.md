# qio 0.0.0.9000

* Fixed compilation with MinGW on Windows when SSE4.2 is not enabled.
* Added persistent `parquet_open()` handles for metadata inspection, projected
  and row-group-aware `collect()` calls, and bounded-memory `walk_batches()`
  processing.
* `read_parquet()` now uses the same open, collect, and close path as the lazy
  API.
