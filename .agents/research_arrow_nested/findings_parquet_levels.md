# Apache Arrow nested Parquet reading

Research date: 2026-07-31. Sources are limited to official Apache Parquet and
Apache Arrow documentation and source.

## Format facts

- Parquet stores only primitive leaf columns. Every leaf has its own definition
  levels and, when its path contains repetition, repetition levels. Definition
  levels say how far down the optional path a record is defined; repetition
  levels say which repeated ancestor is continuing. Null values have no entry in
  the encoded value stream.
- A repetition level of zero starts a new top-level record. Higher levels
  continue a repeated ancestor. Therefore a reader batching by logical rows must
  inspect repetition levels and must not treat a requested number of encoded
  values as the same number of rows.
- Pages in different leaf columns are not aligned. A nested reader cannot zip
  pages across sibling leaves; it must independently decode them and coordinate
  them by logical-record boundaries. Row groups contain the same number of
  top-level rows, but each leaf can have different page and value counts.

Sources:

- <https://github.com/apache/parquet-format/blob/master/README.md#nested-encoding>
- <https://arrow.apache.org/blog/2022/10/17/arrow-parquet-encoding-part-3/>

## Null lists, empty lists, and null elements

- The canonical Parquet `LIST` is a three-level schema: an optional/required
  outer group, a repeated `list` group, and an optional/required `element`.
  These independent repetition choices encode list nullability and element
  nullability.
- Arrow materializes a list as an offsets buffer, an optional list validity
  bitmap, and a child array with its own validity. Consequently:
  - a null list has a false parent-validity bit and does not advance the offset;
  - an empty list is valid and has equal adjacent offsets;
  - a null element advances the offset and adds a null child slot;
  - a value advances the offset and adds a valid child value.
- In Arrow Rust's `ListArrayReader`, for a nullable list at its list definition
  threshold, a level at or above the threshold contributes a child slot, one
  below represents a present-but-empty list, and lower levels represent a null
  list. Repetition levels identify list boundaries and exclude continuations of
  deeper nested lists.
- Readers also need the Parquet compatibility rules for historical one- and
  two-level list encodings. A v0.1 implementation can deliberately support only
  the canonical three-level form, provided unsupported schemas fail clearly.

Sources:

- <https://github.com/apache/parquet-format/blob/master/LogicalTypes.md#lists>
- <https://arrow.apache.org/blog/2022/10/08/arrow-parquet-encoding-part-2/>
- <https://github.com/apache/arrow-rs/blob/main/parquet/src/arrow/array_reader/list_array.rs>

## Arrow's reconstruction approach

- Arrow first converts the Parquet schema into an Arrow schema tree plus
  per-node Dremel information. Arrow Rust calls this `FieldLevels`: it stores
  the projected Arrow fields and the definition/repetition levels required to
  interpret the leaves.
- It then recursively builds readers matching the output tree: primitive leaf
  readers at the bottom, wrapped by list, map, and struct readers.
- A list reader asks its child reader for records and consumes the child's
  definition/repetition levels to build parent offsets and validity.
- A struct reader drives all selected child readers with the same logical batch
  size. It rejects children that report different record counts or produce
  arrays of different lengths. For a nullable struct, it derives the struct
  validity bitmap from a child's level stream, excluding padding from null
  ancestors and repetitions belonging to inner lists.
- This is why nested reconstruction must retain levels after decoding values;
  expanding each primitive leaf to an R vector too early discards the evidence
  needed to rebuild parent containers.

Sources:

- <https://github.com/apache/arrow-rs/blob/main/parquet/src/arrow/schema/mod.rs>
- <https://github.com/apache/arrow-rs/blob/main/parquet/src/arrow/array_reader/builder.rs>
- <https://github.com/apache/arrow-rs/blob/main/parquet/src/arrow/array_reader/struct_array.rs>
- <https://github.com/apache/arrow-rs/blob/main/parquet/src/arrow/array_reader/list_array.rs>

## Schema conversion

- Arrow maps Parquet `LIST` to Arrow `List`, `MAP` to Arrow `Map`, and ordinary
  nested groups to Arrow `Struct`-like hierarchy. Parquet remains authoritative.
- If a file contains serialized `ARROW:schema` metadata, Arrow uses it as a
  compatible hint to restore distinctions Parquet cannot express by itself,
  such as `LargeList` versus `List`; otherwise it uses the default Parquet-to-
  Arrow mapping.
- The Parquet specification requires canonical writers to emit the three-level
  `LIST`, but readers commonly implement legacy-list interpretation rules.

Sources:

- <https://arrow.apache.org/docs/cpp/parquet.html#types>
- <https://arrow.apache.org/docs/cpp/parquet.html#roundtripping-arrow-types-and-schema>
- <https://github.com/apache/parquet-format/blob/master/LogicalTypes.md#nested-types>
- <https://github.com/apache/arrow-rs/blob/main/parquet/src/arrow/schema/mod.rs>

## Projection behavior

- Arrow Rust represents projection as a mask over primitive leaf columns.
- Selecting a root column selects every leaf beneath that root. Selecting a
  named parent path similarly selects all descendant leaves. Selecting individual
  leaves retains the required ancestor wrappers and produces a projected nested
  schema containing only the selected descendants.
- The current Arrow Rust implementation explicitly rejects partial projection
  of a map when only its key or only its value reader is present. This is a useful
  precedent for a staged implementation: support full-parent projection first
  and reject ambiguous partial cases.
- Dot-separated name projection is only a convenience and is ambiguous if field
  names themselves contain dots; Arrow exposes index-based root/leaf projection
  for that case.

Sources:

- <https://github.com/apache/arrow-rs/blob/main/parquet/src/arrow/mod.rs>
- <https://github.com/apache/arrow-rs/blob/main/parquet/src/arrow/array_reader/builder.rs>

## Incremental reading constraints

- Arrow exposes streaming `RecordBatch` readers, so nested data does not require
  materializing the whole file. The batch size counts top-level records, not
  primitive values or list elements.
- Reading a requested number of nullable records requires scanning definition
  levels to learn how many physical values to decode. Reading repeated records
  additionally requires scanning repetition levels until top-level row
  boundaries are known.
- A returned nested batch must begin on a top-level boundary; Arrow Rust's list
  materializer rejects a batch whose first repetition level is not zero.
- A single row may contain a very large list, so the number of decoded child
  values can greatly exceed the nominal row batch size. Incremental reading
  bounds top-level rows, not worst-case memory.
- Struct siblings must advance in lockstep even though their pages are
  unrelated. State therefore needs to survive page and column-chunk transitions.
  Row-group boundaries are natural reset points.

Sources:

- <https://arrow.apache.org/docs/cpp/parquet.html#filereader>
- <https://arrow.apache.org/blog/2022/10/17/arrow-parquet-encoding-part-3/#additional-complications>
- <https://github.com/apache/arrow-rs/blob/main/parquet/src/arrow/array_reader/list_array.rs>
- <https://github.com/apache/arrow-rs/blob/main/parquet/src/arrow/array_reader/struct_array.rs>

## Practical staged subset for qio

The Arrow approach is implementable incrementally. A defensible order is:

1. **Optional/required structs containing non-repeated primitive leaves.** Each
   leaf still has one level entry per top-level row, so child coordination is
   comparatively simple. Return an R data-frame-like object or named list-column
   representation only after its semantics are decided.
2. **Canonical three-level lists of primitive elements.** Build R list-columns
   from offsets and validity while preserving null list, empty list, null
   element, and value as four distinct states. Batch only at repetition-level
   zero boundaries.
3. **Lists of structs and structs of lists.** Add recursive parent construction,
   compact child padding, and cross-leaf synchronization.
4. **Maps and legacy list encodings.** Maps add key/value invariants and partial-
   projection constraints; legacy list schemas add substantial schema ambiguity.

For an intentionally smaller first step, qio could support only full top-level
parent projection, canonical `LIST`, a single repeated layer, and primitive list
elements. It should reject unsupported nesting during schema planning rather
than flattening it or silently collapsing null and empty states.

