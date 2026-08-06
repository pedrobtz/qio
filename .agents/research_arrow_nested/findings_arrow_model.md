# Arrow nested data model and R representation

## Arrow's in-memory model

- Every Arrow array has a type, buffers, length, and null count. Nested arrays
  additionally own child arrays. Except for unions, each nested array has its
  own validity bitmap independently of its children. A cleared bit means the
  parent value is null; masked child data must not be used to infer validity.
- This independence is essential for preserving distinctions such as a null
  struct versus a valid struct whose fields are all null, and a null list
  versus a valid empty list.

Source: [Arrow Columnar Format: physical layout and validity](https://arrow.apache.org/docs/format/Columnar.html#physical-memory-layout)

## Struct

- A `StructArray` has one named child array per field. Every child has the same
  logical length as the parent, but each child has its own type and validity.
  A child value is logically valid only when both the parent struct slot and
  the child slot are valid.
- Arrow R exposes a `StructArray` with field access by name or position and a
  `Flatten()` method. Materializing a struct returns a tibble-like data frame
  with one column per field. The converter calls Arrow's `Flatten()` first,
  merging parent nulls into the child arrays.
- Consequence: after conversion to an ordinary R data-frame column, a null
  struct is represented by nulls in all its fields. The separate parent
  validity is no longer present, so it cannot be distinguished from a valid
  struct whose fields are all null. Keeping an Arrow array can preserve that
  distinction; an ordinary data frame cannot without extra representation.

Sources:

- [Arrow Columnar Format: Struct layout and validity](https://arrow.apache.org/docs/format/Columnar.html#struct-layout)
- [Arrow R `StructArray` interface](https://github.com/apache/arrow/blob/main/r/R/array.R#L435-L481)
- [Arrow R struct-to-R converter](https://github.com/apache/arrow/blob/main/r/src/array_to_vector.cpp#L740-L819)

## List, LargeList, and FixedSizeList

- A variable-size `List<T>` consists of a validity bitmap, `length + 1`
  offsets, and one child array. Slot `i` references the child slice
  `[offset[i], offset[i + 1])`. `List` uses signed 32-bit offsets;
  `LargeList` uses signed 64-bit offsets.
- Equal adjacent offsets describe a zero-length slice. The validity bit then
  distinguishes a valid empty list from a null list. A null list is even
  allowed to reference a non-empty child segment whose content is arbitrary,
  so nullness must come from validity rather than offsets.
- `FixedSizeList<T>[N]` has a child array and a parent validity bitmap but no
  offsets: slot `i` occupies the `N` child positions beginning at `i * N`.
  Child positions still exist for a null parent and are masked by its validity.
- Arrow R exposes separate `ListArray`, `LargeListArray`, and
  `FixedSizeListArray` classes. The variable-list classes expose the child
  values, per-slot offset and length, and raw offsets.
- Materialization produces an R list-column with Arrow/vctrs list classes and
  a child `ptype` attribute. Each valid slot is recursively converted from its
  child slice. Null list slots remain `NULL`; valid empty slots become typed
  zero-length R objects. `FixedSizeList` uses the same recursive list-column
  approach and also retains a `list_size` attribute.

Sources:

- [Arrow Columnar Format: variable-size List layout](https://arrow.apache.org/docs/format/Columnar.html#variable-size-list-layout)
- [Arrow Columnar Format: Fixed-Size List layout](https://arrow.apache.org/docs/format/Columnar.html#fixed-size-list-layout)
- [Arrow R list-array interfaces](https://github.com/apache/arrow/blob/main/r/R/array.R#L487-L534)
- [Arrow R list-to-R converter](https://github.com/apache/arrow/blob/main/r/src/array_to_vector.cpp#L1019-L1118)
- [Arrow R list result classes](https://github.com/apache/arrow/blob/main/r/src/symbols.cpp#L71-L76)

## Map

- Arrow defines `Map<K,V>` as a variable-size list whose child is an
  `entries` struct containing `key` and `value`. The `entries` field and `key`
  field are non-nullable; values may be nullable. `keysSorted` records whether
  keys within each map are sorted. Systems without map-specific behavior can
  treat it as its underlying list-of-struct representation.
- Arrow R's `MapArray` inherits `ListArray` and exposes flattened `keys()` and
  `items()` as well as list-shaped `keys_nested()` and `items_nested()`.
- The R materializer deliberately uses the ordinary list converter with the
  map's entry-struct type. Thus a map column becomes an R list-column where
  each valid element is a two-column tibble/data frame (`key`, `value`), a
  null map is `NULL`, and an empty map is a zero-row entry data frame. This is
  an inference from the converter implementation and the tested
  list-of-data-frames round trip.

Sources:

- [Authoritative Arrow `Map` schema definition](https://github.com/apache/arrow/blob/main/format/Schema.fbs#L131-L146)
- [Arrow R `MapArray` interface](https://github.com/apache/arrow/blob/main/r/R/array.R#L550-L559)
- [Arrow R map test and R representation](https://github.com/apache/arrow/blob/main/r/tests/testthat/test-Array.R#L669-L692)
- [Arrow R converter dispatch for Map](https://github.com/apache/arrow/blob/main/r/src/array_to_vector.cpp#L1362-L1366)

## Conversion to R tabular results

- `Array$create()` accepts R vectors, lists, or data frames. A data frame maps
  to a struct array; homogeneous R lists map to list arrays; Arrow R tests map
  a list of two-column data frames to `MapArray` when a map type is supplied.
- Collecting an Arrow `Table` or `RecordBatch` creates a tibble-like data frame
  and recursively materializes every column. List and map columns therefore
  remain list-columns. A struct column becomes an embedded data-frame/tibble
  column, while a standalone `StructArray` materializes as a data frame.
- Arrow's R-specific metadata can preserve R attributes during an R-to-Arrow-
  to-R round trip, but it is separate from the language-neutral Arrow schema
  and is ignored by other Arrow implementations. It is not a general solution
  for nested values read from arbitrary Parquet files.

Sources:

- [Arrow R array construction documentation/source](https://github.com/apache/arrow/blob/main/r/R/array.R#L19-L35)
- [Arrow R recursive table-to-data-frame conversion](https://github.com/apache/arrow/blob/main/r/src/array_to_vector.cpp#L1380-L1415)
- [Arrow R schema metadata documentation](https://arrow.apache.org/docs/11.0/r/reference/Schema.html#details)

## Implications for an Arrow-like qio API

- The simplest Arrow-like materialized subset is: structs as nested data-frame
  columns, lists as list-columns, and maps as list-columns of two-column data
  frames.
- List nullness can be represented naturally in R as `NULL`, distinct from a
  typed empty vector. Struct parent nullness cannot be represented losslessly
  by only flattening it to child columns; exact preservation would require a
  validity attribute/class or a row-wise list representation.
- Recursive composition is the core approach: reconstruct each nested node's
  validity and boundaries, then recursively materialize its children. Merely
  decoding leaf values is insufficient because offsets and parent validity
  carry user-visible information.
