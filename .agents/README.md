# qio development documentation

This directory contains internal documentation used to develop and maintain
`qio`. It is excluded from the R source package.

Start with:

- [`roadmap.md`](roadmap.md) — concise R API status, remaining implementation
  work, settled decisions, and known limitations.
- [`../AGENTS.md`](../AGENTS.md) — contributor guidelines, repository
  architecture, development commands, and implementation guidance.

Supporting records:

- [`TYPES.md`](TYPES.md) — Parquet-to-R type decisions and coverage plan.
- [`design.md`](design.md) — resolved and open API representation choices.
- [`carquet.md`](carquet.md) — inventory of the vendored carquet API.
- [`VENDORED.md`](VENDORED.md) — pinned dependencies, local patches, and
  re-vendoring procedure.

`README.md`, `NEWS.md`, and license files remain at the repository root because
they are package- and user-facing. Test fixture provenance remains beside the
fixtures under `tests/testthat/parquet/`.
