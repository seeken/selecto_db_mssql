defmodule SelectoDBMSSQL.WriteExecutionIntegrationTest do
  use ExUnit.Case, async: false

  alias Selecto.Write.{Batch, Command, Error, Graph, Result}
  alias Selecto.Write.Graph.{Binding, Node, Row}
  alias SelectoDBMSSQL.Adapter

  @moduletag :requires_db
  @moduletag :mssql
  @moduletag timeout: 120_000

  test "executes governed flat writes and HOLDLOCK MERGE against SQL Server" do
    with_fixture(fn fixture ->
      assert Adapter.write_capabilities(fixture.conn).server_version =~ ~r/^\d+\.\d+/

      assert {:ok, %Result{affected_rows: 1, rows: [inserted]}} =
               Adapter.execute_write(
                 fixture.conn,
                 command!(:insert, fixture.items,
                   assignments: [
                     assignment(:tenant_id, 45),
                     assignment(:external_id, "flat-1"),
                     assignment(:name, "created")
                   ],
                   returning: [:id, :tenant_id, :external_id, :name]
                 ),
                 []
               )

      item_id = fetch_field!(inserted, :id)
      assert fetch_field!(inserted, :tenant_id) == 45

      tenant_predicate =
        {:and,
         [
           {:eq, {:field, :id}, {:literal, item_id}},
           {:eq, {:field, :tenant_id}, {:context, :tenant_id}}
         ]}

      assert {:ok, %Result{affected_rows: 1, rows: [updated]}} =
               Adapter.execute_write(
                 fixture.conn,
                 command!(:update, fixture.items,
                   assignments: [assignment(:name, "tenant-updated")],
                   predicate: tenant_predicate,
                   returning: [:id, :name]
                 ),
                 context: %{tenant_id: 45}
               )

      assert fetch_field!(updated, :name) == "tenant-updated"

      assert {:error, %Error{type: :cardinality_mismatch, details: %{actual: 0}}} =
               Adapter.execute_write(
                 fixture.conn,
                 command!(:update, fixture.items,
                   assignments: [assignment(:name, "cross-tenant")],
                   predicate: tenant_predicate
                 ),
                 context: %{tenant_id: 99}
               )

      assert scalar!(
               fixture.conn,
               "SELECT [name] FROM #{quoted(fixture.items)} WHERE [id] = @p1",
               [item_id]
             ) ==
               "tenant-updated"

      upsert =
        command!(:upsert, fixture.items,
          assignments: [
            assignment(:tenant_id, 45),
            assignment(:external_id, "merge-1"),
            assignment(:name, "merged-created")
          ],
          returning: [:id, :name],
          metadata: %{
            conflict_target: [:tenant_id, :external_id],
            declared_conflict_targets: [[:tenant_id, :external_id]],
            upsert_update_fields: [:name]
          }
        )

      assert {:ok, %Result{affected_rows: 1, rows: [merged_insert]}} =
               Adapter.execute_write(fixture.conn, upsert, [])

      merge_id = fetch_field!(merged_insert, :id)
      assert fetch_field!(merged_insert, :name) == "merged-created"

      changed =
        update_in(upsert.assignments, fn assignments ->
          Enum.map(assignments, fn
            %{field: :name} = assignment -> %{assignment | value: {:literal, "merged-updated"}}
            assignment -> assignment
          end)
        end)

      assert {:ok, %Result{affected_rows: 1, rows: [merged_update]}} =
               Adapter.execute_write(fixture.conn, changed, [])

      assert fetch_field!(merged_update, :id) == merge_id
      assert fetch_field!(merged_update, :name) == "merged-updated"

      assert {:error, %Error{type: :cardinality_mismatch, details: %{actual: 0}}} =
               Adapter.execute_write(
                 fixture.conn,
                 command!(:insert, fixture.items,
                   assignments: [
                     assignment(:tenant_id, 999),
                     assignment(:external_id, "guarded-out"),
                     assignment(:name, "must-not-exist")
                   ],
                   metadata: %{
                     foreign_key_guards: [
                       %{field: :tenant_id, relation: fixture.tenants, target_field: :id}
                     ]
                   }
                 ),
                 []
               )

      assert scalar!(
               fixture.conn,
               "SELECT COUNT(*) FROM #{quoted(fixture.items)} WHERE [external_id] = @p1",
               ["guarded-out"]
             ) ==
               0

      delete_predicate =
        {:and,
         [
           {:eq, {:field, :id}, {:literal, item_id}},
           {:eq, {:field, :tenant_id}, {:literal, 45}}
         ]}

      assert {:ok, %Result{operation: :delete, affected_rows: 1, rows: [deleted]}} =
               Adapter.execute_write(
                 fixture.conn,
                 command!(:delete, fixture.items,
                   assignments: [],
                   predicate: delete_predicate,
                   returning: [:id]
                 ),
                 []
               )

      assert fetch_field!(deleted, :id) == item_id
    end)
  end

  test "rolls back failed batches and generated-key graphs atomically" do
    with_fixture(fn fixture ->
      first =
        command!(:insert, fixture.items,
          assignments: [
            assignment(:tenant_id, 45),
            assignment(:external_id, "batch-first"),
            assignment(:name, "first")
          ]
        )

      fails_cardinality =
        command!(:update, fixture.items,
          assignments: [assignment(:name, "never")],
          predicate: {:eq, {:field, :external_id}, {:literal, "missing"}}
        )

      {:ok, batch} = Batch.new([first, fails_cardinality])

      assert {:error, %Error{type: :cardinality_mismatch}} =
               Adapter.execute_write(fixture.conn, batch, [])

      assert scalar!(
               fixture.conn,
               "SELECT COUNT(*) FROM #{quoted(fixture.items)} WHERE [external_id] = @p1",
               ["batch-first"]
             ) ==
               0

      root =
        command!(:insert, fixture.items,
          assignments: [
            assignment(:tenant_id, 45),
            assignment(:external_id, "graph-root"),
            assignment(:name, "root")
          ],
          returning: [:id]
        )

      child =
        command!(:insert, fixture.children,
          assignments: [assignment(:name, "child")],
          returning: [:id]
        )

      graph = graph!(root, child)

      assert {:ok, %Result{operation: :graph, affected_rows: 2, rows: [root_row]}} =
               Adapter.execute_write(fixture.conn, graph, [])

      root_id = fetch_field!(root_row, :id)

      assert scalar!(
               fixture.conn,
               "SELECT COUNT(*) FROM #{quoted(fixture.children)} WHERE [item_id] = @p1",
               [root_id]
             ) == 1

      bad_root =
        update_in(root.assignments, fn assignments ->
          Enum.map(assignments, fn
            %{field: :external_id} = assignment ->
              %{assignment | value: {:literal, "graph-rollback"}}

            assignment ->
              assignment
          end)
        end)

      bad_child = %{child | assignments: [assignment(:name, nil)]}

      assert {:error, %Error{type: :execution_failed}} =
               Adapter.execute_write(fixture.conn, graph!(bad_root, bad_child), [])

      assert scalar!(
               fixture.conn,
               "SELECT COUNT(*) FROM #{quoted(fixture.items)} WHERE [external_id] = @p1",
               ["graph-rollback"]
             ) ==
               0
    end)
  end

  defp graph!(root, child) do
    nodes = [
      %Node{
        id: "root",
        path: [],
        relation: root.relation,
        strategy: :ordered,
        rows: [%Row{id: "root", path: [], command: root}]
      },
      %Node{
        id: "children",
        path: [:children],
        relation: child.relation,
        strategy: :ordered,
        rows: [
          %Row{
            id: "child",
            path: [:children, 0],
            command: child,
            bindings: [
              %Binding{
                field: :item_id,
                from_node: "root",
                from_row: "root",
                from_field: :id
              }
            ]
          }
        ]
      }
    ]

    {:ok, graph} = Graph.new(nodes, {"root", "root"})
    graph
  end

  defp with_fixture(fun) do
    {:ok, conn} = Adapter.connect(connection_options())
    suffix = System.unique_integer([:positive, :monotonic])

    fixture = %{
      conn: conn,
      tenants: "dbo.selecto_write_tenants_#{suffix}",
      items: "dbo.selecto_write_items_#{suffix}",
      children: "dbo.selecto_write_children_#{suffix}"
    }

    execute!(conn, "CREATE TABLE #{quoted(fixture.tenants)} ([id] int NOT NULL PRIMARY KEY)")

    try do
      execute!(conn, """
      CREATE TABLE #{quoted(fixture.items)} (
        [id] int IDENTITY(1,1) NOT NULL PRIMARY KEY,
        [tenant_id] int NOT NULL,
        [external_id] nvarchar(80) NOT NULL,
        [name] nvarchar(120) NOT NULL,
        CONSTRAINT [uq_items_#{suffix}] UNIQUE ([tenant_id], [external_id]),
        CONSTRAINT [fk_items_tenant_#{suffix}] FOREIGN KEY ([tenant_id]) REFERENCES #{quoted(fixture.tenants)} ([id])
      )
      """)

      execute!(conn, """
      CREATE TABLE #{quoted(fixture.children)} (
        [id] int IDENTITY(1,1) NOT NULL PRIMARY KEY,
        [item_id] int NOT NULL,
        [name] nvarchar(120) NOT NULL,
        CONSTRAINT [fk_children_item_#{suffix}] FOREIGN KEY ([item_id]) REFERENCES #{quoted(fixture.items)} ([id])
      )
      """)

      execute!(conn, "INSERT INTO #{quoted(fixture.tenants)} ([id]) VALUES (45), (99)")
      fun.(fixture)
    after
      Adapter.execute(conn, "DROP TABLE IF EXISTS #{quoted(fixture.children)}", [], [])
      Adapter.execute(conn, "DROP TABLE IF EXISTS #{quoted(fixture.items)}", [], [])
      Adapter.execute(conn, "DROP TABLE IF EXISTS #{quoted(fixture.tenants)}", [], [])
      if Process.alive?(conn), do: GenServer.stop(conn)
    end
  end

  defp command!(operation, relation, overrides) do
    defaults = %{
      operation: operation,
      relation: relation,
      assignments: [],
      predicate: nil,
      expected_cardinality: {:exactly, 1},
      returning: :none,
      metadata: %{}
    }

    {:ok, command} = Command.new(Map.merge(defaults, Map.new(overrides)))
    command
  end

  defp assignment(field, value), do: %{field: field, value: {:literal, value}}

  defp execute!(conn, sql) do
    assert {:ok, _result} = Adapter.execute(conn, sql, [], [])
  end

  defp scalar!(conn, sql, params) do
    assert {:ok, %{rows: [[value]]}} = Adapter.execute(conn, sql, params, [])
    value
  end

  defp fetch_field!(row, field) do
    {_key, value} = Enum.find(row, fn {key, _value} -> to_string(key) == to_string(field) end)
    value
  end

  defp quoted(relation) do
    relation
    |> String.split(".")
    |> Enum.map_join(".", &"[#{String.replace(&1, "]", "]]")}]")
  end

  defp connection_options do
    [
      hostname: System.get_env("SELECTO_MSSQL_HOST", "127.0.0.1"),
      port: System.get_env("SELECTO_MSSQL_PORT", "1433") |> String.to_integer(),
      username: System.get_env("SELECTO_MSSQL_USER", "sa"),
      password: System.fetch_env!("SELECTO_MSSQL_PASSWORD"),
      database: System.get_env("SELECTO_MSSQL_DATABASE", "master"),
      ssl: false
    ]
  end
end
