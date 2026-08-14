# SelectoDBMSSQL

Microsoft SQL Server adapter package for the Selecto ecosystem.

This package provides `SelectoDBMSSQL.Adapter`, an external adapter module for
using Selecto against SQL Server via `tds`.

## Installation

```elixir
def deps do
  [
    {:selecto, ">= 0.5.0 and < 0.6.0"},
    {:selecto_db_mssql, "~> 0.2"}
  ]
end
```

## Usage

Pass the adapter explicitly when configuring Selecto:

```elixir
selecto =
  Selecto.configure(domain, mssql_opts,
    adapter: SelectoDBMSSQL.Adapter
  )
```

## Notes

- Placeholder style is `@pN`.
- Identifier quoting uses brackets.
- Streaming is not currently supported.
- Portable flat writes use bound `@pN` values and `OUTPUT` projections.
- Atomic batches and generated-key graphs use one TDS transaction.
- Upserts compile to `MERGE WITH (HOLDLOCK)`; live service verification of
  concurrency and trigger behavior is required for production qualification.

## Local Workspace Development

For local multi-repo development against vendored ecosystem packages, set:

```bash
SELECTO_ECOSYSTEM_USE_LOCAL=true
```

When enabled, this package resolves `{:selecto, path: "../selecto"}`.

## Live Release Verification

Live tests are excluded from the default suite. Point the adapter at an
isolated SQL Server database and run:

```bash
SELECTO_MSSQL_PASSWORD='...' \
SELECTO_MSSQL_HOST=127.0.0.1 \
SELECTO_MSSQL_PORT=1433 \
mix test test/selecto_db_mssql/execution_integration_test.exs \
  test/selecto_db_mssql/write_execution_integration_test.exs \
  --include requires_db
```

The write suite creates uniquely named tables, verifies cleanup and rollback,
and drops the tables before disconnecting. Credentials are required explicitly;
the test harness contains no password fallback.
