# qio/carquet feasibility notes

## Existing support

- `carquet_column_read_batch()` exposes decoded primitive values together with
  definition and repetition levels, which are the essential inputs for nested
  reconstruction.
- The schema API exposes leaf paths and maximum definition/repetition levels.
  `carquet_count_rows()` counts repetition-level-zero entries, and
  `carquet_list_offsets()` derives boundaries from repetition levels.
- qio currently rejects every leaf whose path depth is greater than one or
  whose maximum repetition level is nonzero (`src/qio_file.c`). Its R read plan
  makes the same policy explicit (`R/parquet-plan.R`).

## Missing assembly layer

- Nested reading cannot use qio's current flat scatter directly: repeated
  leaves have a level-entry count different from both their dense value count
  and the number of top-level rows.
- `carquet_list_offsets()` alone is insufficient because it ignores definition
  levels. A combined definition/repetition state machine must preserve null
  list, empty list, null element, and present value as distinct states.
- Sibling leaves can have unrelated page boundaries. Structs, lists of structs,
  and maps therefore require persistent per-leaf state coordinated at logical
  row boundaries.
- The internal carquet schema contains parent indices and child counts, but the
  public node API may need small traversal accessors so qio can build a complete
  output schema tree without duplicating schema parsing.

## Safe staged implementation

1. As a transitional feature, collect non-repeated nested leaves as flattened
   dotted-path columns. This is row-aligned but deliberately does not preserve
   parent-struct validity.
2. Add required/non-repeated structs of primitive leaves.
3. Add canonical three-level, one-layer lists of primitive elements as base R
   list-columns. Require full-parent projection and end batches only at
   repetition-level-zero row boundaries.
4. Add optional structs and recursive list/struct combinations after choosing
   how qio will represent parent-struct validity in R.
5. Defer maps, legacy list encodings, and arbitrary recursive nesting.

Unsupported shapes should fail during planning with the offending schema path;
they must never be silently flattened or have null and empty states collapsed.
