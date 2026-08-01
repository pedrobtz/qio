# Maintainer documentation

These files are internal development records and are excluded from the R source
package. Each topic has one owner:

| File | Owns |
|---|---|
| [`../AGENTS.md`](../AGENTS.md) | Repository rules, architecture, and commands |
| [`roadmap.md`](roadmap.md) | Current API, release scope, priorities, and open product choices |
| [`plan.md`](plan.md) | Ordered v0.1.0 work, dependencies, and release gates |
| [`TYPES.md`](TYPES.md) | Current and target Parquet-to-R mappings and conversion contracts |
| [`carquet.md`](carquet.md) | qio's integration with the vendored carquet snapshot |
| [`VENDORED.md`](VENDORED.md) | Dependency pins, local patches, and re-vendoring |

`research_arrow_nested/` contains background research, not current requirements.
When it conflicts with `TYPES.md` or `roadmap.md`, those documents win.

User-facing documentation (`README.md`, `NEWS.md`, and licenses) stays at the
repository root. Fixture provenance stays beside the fixtures under
`tests/testthat/parquet/`.
