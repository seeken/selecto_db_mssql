# Changelog

## 0.5.0 - 2026-08-14

- Removed renderer aliases for the retired `json_extract_path` and
  `json_extract_path_text` core operations.
- Normalize the custom O'Saasy Hex metadata to `LicenseRef-O-Saasy`; the
  packaged license text and licensing terms are unchanged.
- Raised the Selecto baseline to `0.5.0` and implemented the explicit runtime,
  normalized result/error/type, and SQL Server-owned dialect-fragment ports.
- Unsupported PostgreSQL-shaped features now fail with structured capability
  evidence instead of inheriting core fallback SQL.
- SQL Server now owns portable datetime-format and case-insensitive comparison
  rendering and explicitly rejects unsupported timezone/epoch conversion.

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
