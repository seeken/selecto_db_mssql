defmodule SelectoDBMSSQL.TenantForeignKeyGuardTest do
  use ExUnit.Case, async: false

  alias Selecto.Write.{Command, Error, Preview, Result}
  alias SelectoDBMSSQL.Adapter

  @guard_sql "EXISTS (SELECT 1 FROM [projects] AS [selecto_fk_parent] " <>
               "WHERE [selecto_fk_parent].[id] = @p~B AND [selecto_fk_parent].[tenant_id] = @p~B)"

  test "a tenant guard binds the referenced row's tenant behind an alias" do
    assert {:ok, %Preview{statements: [%{text: insert_sql, params: [7, 80, "t", 80, 7]}]}} =
             Adapter.preview_write(:unused, insert!("projects", "tasks", 80, "t"), [])

    assert insert_sql =~ "SELECT @p1, @p2, @p3 WHERE " <> guard_sql(4, 5)

    assert {:ok, %Preview{statements: [%{text: update_sql, params: [80, "t", 1, 7, 80, 7]}]}} =
             Adapter.preview_write(:unused, update!("projects", "tasks", 80, "t"), [])

    assert update_sql =~ "AND " <> guard_sql(5, 6)

    assert {:ok, %Preview{statements: [%{text: merge_sql, params: [7, 80, "t", 80, 7]}]}} =
             Adapter.preview_write(:unused, upsert!("projects", "tasks", 80, "t"), [])

    assert merge_sql =~ "WHEN MATCHED AND (" <> guard_sql(4, 5) <> ")"
    assert merge_sql =~ "WHEN NOT MATCHED AND (" <> guard_sql(4, 5) <> ")"
  end

  test "update guards are numbered at compile time, not by rewriting identifier text" do
    command = update!("dbo.projects@p1", "tasks", 80, "t")

    assert {:ok, %Preview{statements: [%{text: sql, params: [80, "t", 1, 7, 80, 7]}]}} =
             Adapter.preview_write(:unused, command, [])

    assert sql =~
             "FROM [dbo].[projects@p1] AS [selecto_fk_parent] " <>
               "WHERE [selecto_fk_parent].[id] = @p5 AND [selecto_fk_parent].[tenant_id] = @p6"
  end

  test "a guard naming a tenant field without a usable tenant value fails closed" do
    base = Map.drop(guard("projects"), [:tenant_field, :tenant_value])

    for invalid <- [
          Map.put(base, :tenant_field, :tenant_id),
          Map.merge(base, %{tenant_field: :tenant_id, tenant_value: nil}),
          Map.merge(base, %{tenant_field: 7, tenant_value: 7}),
          Map.merge(base, %{tenant_field: nil, tenant_value: 7}),
          Map.merge(base, %{tenant_field: " ", tenant_value: 7})
        ] do
      command = insert!("projects", "tasks", 80, "t")
      command = %{command | metadata: %{foreign_key_guards: [invalid]}}

      assert {:error, %Error{type: :invalid_foreign_key_guard}} =
               Adapter.preview_write(:unused, command, [])
    end
  end

  @tag :requires_db
  @tag :mssql
  @tag timeout: 120_000
  test "a tenant-7 write cannot reference tenant 8's parent" do
    with_fixture(fn %{conn: conn, projects: projects, tasks: tasks} ->
      assert {:error, %Error{type: :cardinality_mismatch, details: %{actual: 0}}} =
               Adapter.execute_write(conn, insert!(projects, tasks, 80, "inserted"), [])

      assert {:error, %Error{type: :cardinality_mismatch, details: %{actual: 0}}} =
               Adapter.execute_write(conn, update!(projects, tasks, 80, "updated"), [])

      assert {:error, %Error{type: :cardinality_mismatch, details: %{actual: 0}}} =
               Adapter.execute_write(conn, upsert!(projects, tasks, 80, "upserted"), [])

      assert task_rows(conn, tasks) == [[1, 7, 70, "seed"]]

      assert {:ok, %Result{affected_rows: 1}} =
               Adapter.execute_write(conn, insert!(projects, tasks, 70, "inserted"), [])

      assert {:ok, %Result{affected_rows: 1}} =
               Adapter.execute_write(conn, update!(projects, tasks, 70, "updated"), [])

      assert {:ok, %Result{affected_rows: 1}} =
               Adapter.execute_write(conn, upsert!(projects, tasks, 70, "upserted"), [])

      assert task_rows(conn, tasks) == [
               [1, 7, 70, "updated"],
               [2, 7, 70, "inserted"],
               [3, 7, 70, "upserted"]
             ]
    end)
  end

  defp guard_sql(target, tenant), do: :io_lib.format(@guard_sql, [target, tenant]) |> to_string()

  defp guard(projects) do
    %{
      field: :project_id,
      relation: projects,
      target_field: :id,
      tenant_field: :tenant_id,
      tenant_value: 7
    }
  end

  defp insert!(projects, tasks, project_id, name) do
    command!(%{
      operation: :insert,
      relation: tasks,
      assignments: assignments(project_id, name),
      metadata: %{foreign_key_guards: [guard(projects)]}
    })
  end

  defp update!(projects, tasks, project_id, name) do
    command!(%{
      operation: :update,
      relation: tasks,
      assignments: [
        %{field: :project_id, value: {:literal, project_id}},
        %{field: :name, value: {:literal, name}}
      ],
      predicate:
        {:and, [{:eq, {:field, :id}, {:literal, 1}}, {:eq, {:field, :tenant_id}, {:literal, 7}}]},
      metadata: %{foreign_key_guards: [guard(projects)]}
    })
  end

  defp upsert!(projects, tasks, project_id, name) do
    command!(%{
      operation: :upsert,
      relation: tasks,
      assignments: assignments(project_id, name),
      metadata: %{
        foreign_key_guards: [guard(projects)],
        conflict_target: [:tenant_id, :name],
        declared_conflict_targets: [[:tenant_id, :name]],
        upsert_update_fields: [:project_id]
      }
    })
  end

  defp assignments(project_id, name) do
    [
      %{field: :tenant_id, value: {:literal, 7}},
      %{field: :project_id, value: {:literal, project_id}},
      %{field: :name, value: {:literal, name}}
    ]
  end

  defp command!(attrs) do
    {:ok, command} = Command.new(attrs)
    command
  end

  defp task_rows(conn, tasks) do
    {:ok, %{rows: rows}} =
      Adapter.execute(
        conn,
        "SELECT [id], [tenant_id], [project_id], [name] FROM #{quoted(tasks)} ORDER BY [id]",
        [],
        []
      )

    rows
  end

  defp with_fixture(fun) do
    {:ok, conn} = Adapter.connect(connection_options())
    suffix = System.unique_integer([:positive, :monotonic])
    projects = "dbo.selecto_fk_projects_#{suffix}"
    tasks = "dbo.selecto_fk_tasks_#{suffix}"

    try do
      execute!(conn, """
      CREATE TABLE #{quoted(projects)} ([id] int NOT NULL PRIMARY KEY, [tenant_id] int NOT NULL)
      """)

      execute!(conn, """
      CREATE TABLE #{quoted(tasks)} (
        [id] int IDENTITY(1,1) NOT NULL PRIMARY KEY,
        [tenant_id] int NOT NULL,
        [project_id] int NOT NULL,
        [name] nvarchar(40) NOT NULL,
        CONSTRAINT [uq_fk_tasks_#{suffix}] UNIQUE ([tenant_id], [name]),
        CONSTRAINT [fk_fk_tasks_#{suffix}] FOREIGN KEY ([project_id])
          REFERENCES #{quoted(projects)} ([id])
      )
      """)

      execute!(
        conn,
        "INSERT INTO #{quoted(projects)} ([id], [tenant_id]) VALUES (70, 7), (80, 8)"
      )

      execute!(
        conn,
        "INSERT INTO #{quoted(tasks)} ([tenant_id], [project_id], [name]) VALUES (7, 70, 'seed')"
      )

      fun.(%{conn: conn, projects: projects, tasks: tasks})
    after
      Adapter.execute(conn, "DROP TABLE IF EXISTS #{quoted(tasks)}", [], [])
      Adapter.execute(conn, "DROP TABLE IF EXISTS #{quoted(projects)}", [], [])
      if Process.alive?(conn), do: GenServer.stop(conn)
    end
  end

  defp execute!(conn, sql), do: assert({:ok, _result} = Adapter.execute(conn, sql, [], []))

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
