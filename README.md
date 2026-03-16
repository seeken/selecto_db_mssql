# SelectoDBMSSQL

Microsoft SQL Server adapter package for the Selecto ecosystem.

This package provides `SelectoDBMSSQL.Adapter`, an external adapter module for
using Selecto against SQL Server via `tds`.

## Installation

```elixir
def deps do
  [
    {:selecto, "~> 0.4.0"},
    {:selecto_db_mssql, "~> 0.1"}
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

## Local Workspace Development

For local multi-repo development against vendored ecosystem packages, set:

```bash
SELECTO_ECOSYSTEM_USE_LOCAL=true
```

When enabled, this package resolves `{:selecto, path: "../selecto"}`.
