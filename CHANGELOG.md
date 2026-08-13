# Changelog

## 0.2.0 - 2026-08-12

- Added the versioned Selecto portable write contract with `@pN` parameters,
  bracket-quoted identifiers, and `OUTPUT INSERTED`/`OUTPUT DELETED` results.
- Added native `MERGE WITH (HOLDLOCK)` upserts plus ordered atomic graph and
  batch execution through TDS transactions.
- Added the public TDS transaction callback used by the advertised transaction
  capability.
- Added opt-in live SQL Server coverage for bound flat writes, tenant
  cardinality, reference guards, `OUTPUT` decoding, `MERGE WITH (HOLDLOCK)`,
  atomic batch rollback, generated-key graph propagation, and graph rollback.
- Normalized driver command results with `columns: nil` to an empty portable
  column list instead of attempting to enumerate `nil`.
- Live concurrency and trigger matrices remain an external-service release
  gate beyond the sequential transaction/rollback suite.
