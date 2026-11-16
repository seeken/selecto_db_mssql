# SQL Server adapter migration

The legacy `selecto_db_mssql` implementation is frozen at source commit
`f273fbf5f5ababf31877b762dfadaf34108e06d7`. This notice is a later documentation
change, not part of that frozen source commit. Existing copies and their
O'Saasy licence remain unchanged. There is no announced security-only
maintenance commitment for this frozen package.

Future development moves to the separate, private
[`selecto_db_sqlserver`](https://github.com/seeken/selecto_db_sqlserver)
package, with public entry point `SelectoDBSQLServer.Adapter`. The backend
identity remains `mssql`. The new package will provide the legacy module names
for one migration interval; it cannot be installed together with this package
because they would define duplicate modules.

Selecto for SQL Server is an optional adapter for the Selecto Elixir engine.
The intended model is free testing and paid production use. Licence terms are
not finalized and this private package is not released. Microsoft drivers are
separate dependencies governed by their own terms. This project is not
affiliated with or endorsed by Microsoft.

The private package's provisional licence does not grant evaluation,
production or redistribution rights. Keep using an existing authorized pinned
legacy source until an authorized new core+adapter combination is verified and
installation guidance is available. Exact dependency pins and driver/server
combinations belong in the consuming application's lock and certification
receipts. This migration does not imply new SQL Server capabilities.

This repository remains public and is not archived by this change. Archiving
is deferred until consumers have switched. No history, tags, visibility or
existing licence grants are rewritten.
