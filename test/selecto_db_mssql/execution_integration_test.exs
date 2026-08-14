defmodule SelectoDBMSSQL.ExecutionIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :requires_db
  @moduletag timeout: 120_000

  @tag :mssql
  test "mssql adapter executes apply queries" do
    with_mssql_connection(fn conn ->
      sql = """
      SELECT src.id, applied.next_id
      FROM (VALUES (1), (2)) AS src(id)
      OUTER APPLY (
        SELECT src.id + 10 AS next_id
      ) AS applied
      ORDER BY src.id
      """

      assert {:ok, %{rows: rows, columns: columns}} =
               SelectoDBMSSQL.Adapter.execute(conn, sql, [], [])

      assert normalize_columns(columns) == ["id", "next_id"]

      assert Enum.map(rows, fn [id, next_id] ->
               {normalize_scalar(id), normalize_scalar(next_id)}
             end) == [{"1", "11"}, {"2", "12"}]
    end)
  end

  @tag :mssql
  test "mssql adapter executes json_value json_query and openjson queries" do
    with_mssql_connection(fn conn ->
      sql = """
      SELECT
        JSON_VALUE('{"customer":{"name":"Ada"},"tags":["featured","new"]}', '$.customer.name') AS customer_name,
        JSON_QUERY('{"customer":{"name":"Ada"},"tags":["featured","new"]}', '$.tags') AS tags_json,
        (SELECT COUNT(*) FROM OPENJSON('{"customer":{"name":"Ada"},"tags":["featured","new"]}', '$.tags')) AS tag_count
      """

      assert {:ok, %{rows: [[customer_name, tags_json, tag_count]], columns: columns}} =
               SelectoDBMSSQL.Adapter.execute(conn, sql, [], [])

      assert normalize_columns(columns) == ["customer_name", "tags_json", "tag_count"]
      assert normalize_scalar(customer_name) == "Ada"
      assert normalize_scalar(tag_count) == "2"
      assert normalize_scalar(tags_json) =~ ~s("featured")
      assert normalize_scalar(tags_json) =~ ~s("new")
    end)
  end

  @tag :mssql
  test "mssql adapter executes introspection and rollup capabilities" do
    with_mssql_connection(fn conn ->
      table_name = "selecto_mssql_contract_#{System.unique_integer([:positive])}"
      quoted_table = SelectoDBMSSQL.Adapter.quote_identifier(table_name)

      assert {:ok, _result} =
               SelectoDBMSSQL.Adapter.execute(
                 conn,
                 "CREATE TABLE [dbo].#{quoted_table} ([id] INT NOT NULL PRIMARY KEY, [bucket] NVARCHAR(40) NULL)",
                 [],
                 []
               )

      try do
        assert {:ok, _result} =
                 SelectoDBMSSQL.Adapter.execute(
                   conn,
                   "INSERT INTO [dbo].#{quoted_table} ([id], [bucket]) VALUES (1, 'a'), (2, 'b')",
                   [],
                   []
                 )

        assert {:ok, tables} = SelectoDBMSSQL.Adapter.list_tables(conn, schema: "dbo")
        assert table_name in tables

        assert {:ok, relations} =
                 SelectoDBMSSQL.Adapter.list_relations(conn,
                   schema: "dbo",
                   include_views: true
                 )

        assert Enum.any?(relations, &(&1 == %{name: table_name, source_kind: :table}))

        assert {:ok, metadata} =
                 SelectoDBMSSQL.Adapter.introspect_table(conn, table_name,
                   schema: "dbo",
                   expand: false
                 )

        assert metadata.primary_key == :id
        assert metadata.field_types.bucket == :string
        assert metadata.source == :mssql

        assert {:ok, %{rows: rollup_rows}} =
                 SelectoDBMSSQL.Adapter.execute(
                   conn,
                   "SELECT [bucket], COUNT(*) FROM [dbo].#{quoted_table} GROUP BY ROLLUP([bucket])",
                   [],
                   []
                 )

        assert length(rollup_rows) == 3
      after
        SelectoDBMSSQL.Adapter.execute(
          conn,
          "DROP TABLE IF EXISTS [dbo].#{quoted_table}",
          [],
          []
        )
      end
    end)
  end

  defp with_mssql_connection(fun) when is_function(fun, 1) do
    case connect_with_retry(fn -> SelectoDBMSSQL.Adapter.connect(mssql_opts()) end) do
      {:ok, conn} ->
        case SelectoDBMSSQL.Adapter.execute(conn, "SELECT 1", [], []) do
          {:ok, _} ->
            on_exit(fn ->
              close_connection(conn)
            end)

            fun.(conn)

          {:error, _reason} ->
            close_connection(conn)
            assert true
        end

      {:error, {:adapter_dependency_missing, :tds}} ->
        assert true

      {:error, reason} ->
        flunk("live MSSQL execution probes are unavailable: #{inspect(reason)}")
    end
  end

  defp connect_with_retry(fun, attempts \\ 60)

  defp connect_with_retry(fun, attempts) when attempts > 1 do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, {:adapter_dependency_missing, :tds}} = error ->
        error

      {:error, _reason} ->
        Process.sleep(1_000)
        connect_with_retry(fun, attempts - 1)
    end
  end

  defp connect_with_retry(fun, 1), do: fun.()

  defp close_connection(conn) when is_pid(conn) do
    if Process.alive?(conn), do: Process.exit(conn, :normal)
    :ok
  end

  defp close_connection(_), do: :ok

  defp normalize_columns(columns),
    do: Enum.map(columns, fn col -> col |> to_string() |> String.downcase() end)

  defp normalize_scalar(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp normalize_scalar(value) when is_binary(value), do: value
  defp normalize_scalar(value), do: to_string(value)

  defp mssql_opts do
    [
      hostname: env("SELECTO_MSSQL_HOST", "localhost"),
      port: env_int("SELECTO_MSSQL_PORT", 1433),
      username: env("SELECTO_MSSQL_USER", "sa"),
      password: System.fetch_env!("SELECTO_MSSQL_PASSWORD"),
      database: env("SELECTO_MSSQL_DATABASE", "master"),
      ssl: false
    ]
  end

  defp env(name, default), do: System.get_env(name, default)

  defp env_int(name, default) do
    name
    |> env(Integer.to_string(default))
    |> String.to_integer()
  end
end
