# Arrow Nested Reading Research Plan

## Main question

How does Apache Arrow reconstruct nested Parquet data, and which useful subset
can qio implement with the definition/repetition-level facilities exposed by
its vendored carquet library?

## Subtopics

1. **Arrow nested data model and R representation**
   - Establish how Arrow represents structs, lists, maps, offsets, and validity.
   - Establish how the Arrow R package exposes those values when converting to
     R data frames.

2. **Arrow Parquet nested reconstruction**
   - Establish how Arrow maps Parquet schemas and definition/repetition levels
     into nested arrays.
   - Identify projection and null-versus-empty-list behavior.

3. **qio/carquet feasibility**
   - Compare Arrow's requirements with carquet's schema tree, leaf readers,
     definition levels, repetition levels, and list-boundary helpers.
   - Propose a safe incremental subset and test boundaries for qio.

## Synthesis

Combine the two official-source reviews with direct inspection of qio's
vendored carquet APIs. Separate what is mechanically implementable from what
still requires an R API decision, and recommend a bounded first subset.
