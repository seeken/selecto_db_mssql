# selecto_updato is not a dependency of this adapter, and its
# SelectoUpdato.GovernedWrite is the only module Selecto.Write.Authorization
# lets issue an authorization. This stand-in of the same name, compiled only
# for this suite, plays the governed entry point so the adapter's governed
# callbacks can be exercised with a real authorization.
defmodule SelectoUpdato.GovernedWrite do
  @moduledoc false

  alias Selecto.Write.Authorization

  # Matching the result keeps issue/1 out of tail position, so this module's
  # frame is on the stack when Authorization checks its caller.
  def authorize!(write) do
    {:ok, authorization} = Authorization.issue(write)
    authorization
  end

  def prepared(write, context) do
    with {:ok, authorization} <- Authorization.issue(write) do
      {:ok, write, context, authorization}
    end
  end
end

defmodule SelectoDBMSSQL.GovernedWriteBoundaryIntegrationTest do
  use ExUnit.Case, async: false

  alias Selecto.Write.{Authorization, Batch, Command, Error, Graph, Result}
  alias Selecto.Write.Graph.{Node, Row}
  alias SelectoDBMSSQL.Adapter, as: Adapter
  alias SelectoUpdato.GovernedWrite

  @moduletag :requires_db
  @moduletag :mssql
  @moduletag timeout: 120_000

  @seed [[1, 7, "a"], [2, 7, "b"], [3, 8, "c"]]

  setup do
    {:ok, connection} = Adapter.connect(connection_options())

    execute!(connection, "DROP TABLE IF EXISTS [dbo].[selecto_governed_writes]")

    execute!(connection, """
    CREATE TABLE [dbo].[selecto_governed_writes] (
      [id] bigint NOT NULL PRIMARY KEY,
      [tenant_id] bigint NOT NULL,
      [name] nvarchar(255) NOT NULL
    )
    """)

    execute!(
      connection,
      "INSERT INTO [dbo].[selecto_governed_writes] VALUES (1, 7, 'a'), (2, 7, 'b'), (3, 8, 'c')"
    )

    on_exit(fn ->
      {:ok, cleanup} = Adapter.connect(connection_options())
      Adapter.execute(cleanup, "DROP TABLE IF EXISTS [dbo].[selecto_governed_writes]", [], [])
      GenServer.stop(cleanup)
    end)

    %{connection: connection, selecto: %Selecto{adapter: Adapter, connection: connection}}
  end

  test "the normal execute API refuses a raw command, batch, and graph", %{
    connection: connection,
    selecto: selecto
  } do
    for write <- [update(1, "direct"), batch!(), graph!()] do
      assert {:error, %Error{type: :ungoverned_write}} =
               Adapter.execute_write(connection, write, [])

      assert {:error, %Error{type: :ungoverned_write}} = Selecto.Write.execute(selecto, write)
    end

    assert rows(connection) == @seed
  end

  test "a lookalike, spent, or mismatched authorization is refused", %{connection: connection} do
    command = update(1, "forged")
    forged = struct!(Authorization, ref: make_ref())

    assert {:error, %Error{type: :ungoverned_write}} =
             Adapter.execute_write(connection, command, authorization: forged)

    authorization = GovernedWrite.authorize!(command)

    assert {:error, %Error{type: :ungoverned_write}} =
             Adapter.execute_write(connection, update(1, "other"), authorization: authorization)

    authorization = GovernedWrite.authorize!(command)

    assert {:ok, %Result{affected_rows: 1}} =
             Adapter.execute_write(connection, command, authorization: authorization)

    execute!(connection, "UPDATE [dbo].[selecto_governed_writes] SET name = 'a' WHERE id = 1")

    assert {:error, %Error{type: :ungoverned_write}} =
             Adapter.execute_write(connection, command, authorization: authorization)

    assert rows(connection) == @seed
  end

  test "a governed command, batch, and graph execute", %{
    connection: connection,
    selecto: selecto
  } do
    for write <- [update(2, "governed"), batch!(), graph!()] do
      authorization = GovernedWrite.authorize!(write)

      assert {:ok, _result} =
               Selecto.Write.execute(selecto, write, authorization: authorization)
    end

    assert rows(connection) == [
             [1, 7, "batch"],
             [2, 7, "governed"],
             [3, 8, "c"],
             [4, 7, "batch"],
             [5, 7, "graph"]
           ]
  end

  test "the unsafe primitive still executes for trusted tooling", %{connection: connection} do
    assert {:ok, %Result{affected_rows: 1}} =
             Adapter.execute_write_unsafe(connection, update(1, "unsafe"), [])

    assert rows(connection) == [[1, 7, "unsafe"], [2, 7, "b"], [3, 8, "c"]]
  end

  defp update(id, name) do
    {:ok, command} =
      Command.new(%{
        operation: :update,
        relation: "dbo.selecto_governed_writes",
        assignments: [%{field: :name, value: {:literal, name}}],
        predicate: {:eq, {:field, :id}, {:literal, id}}
      })

    command
  end

  defp insert(id, name) do
    {:ok, command} =
      Command.new(%{
        operation: :insert,
        relation: "dbo.selecto_governed_writes",
        assignments: [
          %{field: :id, value: {:literal, id}},
          %{field: :tenant_id, value: {:literal, 7}},
          %{field: :name, value: {:literal, name}}
        ],
        returning: [:id]
      })

    command
  end

  defp batch! do
    {:ok, batch} = Batch.new([update(1, "batch"), insert(4, "batch")])
    batch
  end

  defp graph! do
    {:ok, graph} =
      Graph.new(
        [
          %Node{
            id: "root",
            path: [],
            relation: "dbo.selecto_governed_writes",
            strategy: :ordered,
            rows: [%Row{id: "root", path: [], command: insert(5, "graph")}]
          }
        ],
        {"root", "root"}
      )

    graph
  end

  defp rows(connection) do
    {:ok, %{rows: rows}} =
      Adapter.execute(
        connection,
        "SELECT [id], [tenant_id], [name] FROM [dbo].[selecto_governed_writes] ORDER BY [id]",
        [],
        []
      )

    rows
  end

  defp execute!(connection, sql) do
    {:ok, result} = Adapter.execute(connection, sql, [], [])
    result
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
