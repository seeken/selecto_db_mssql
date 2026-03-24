defmodule SelectoDBMSSQL.AdapterTest do
  use ExUnit.Case, async: true

  test "adapter exposes the selecto adapter contract" do
    assert Code.ensure_loaded?(SelectoDBMSSQL.Adapter)
    assert function_exported?(SelectoDBMSSQL.Adapter, :name, 0)
    assert function_exported?(SelectoDBMSSQL.Adapter, :connect, 1)
    assert function_exported?(SelectoDBMSSQL.Adapter, :execute, 4)
    assert function_exported?(SelectoDBMSSQL.Adapter, :placeholder, 1)
    assert function_exported?(SelectoDBMSSQL.Adapter, :quote_identifier, 1)
    assert function_exported?(SelectoDBMSSQL.Adapter, :supports?, 1)
  end

  test "mssql adapter reports expected placeholder and quoting strategy" do
    assert SelectoDBMSSQL.Adapter.placeholder(3) |> IO.iodata_to_binary() == "@p3"
    assert SelectoDBMSSQL.Adapter.quote_identifier("order") == "[order]"
  end

  test "mssql adapter rejects invalid connection options" do
    assert SelectoDBMSSQL.Adapter.connect(123) == {:error, {:invalid_connection_options, 123}}
  end

  test "mssql adapter returns a dependency or connection result" do
    result = SelectoDBMSSQL.Adapter.connect([])

    if Code.ensure_loaded?(Tds) do
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    else
      assert result == {:error, {:adapter_dependency_missing, :tds}}
    end
  end

  test "mssql adapter does not claim stream support" do
    refute SelectoDBMSSQL.Adapter.supports?(:stream)
  end

  test "mssql adapter reports rollup support" do
    assert SelectoDBMSSQL.Adapter.supports?(:rollup)
  end

  test "mssql adapter reports schema introspection support" do
    assert SelectoDBMSSQL.Adapter.supports?(:schema_introspection)
  end

  test "mssql adapter reports apply-based lateral join support" do
    assert SelectoDBMSSQL.Adapter.supports?(:lateral_join)
    assert SelectoDBMSSQL.Adapter.supports?(:apply_join)
  end

  test "mssql adapter lists tables for selecto_mix generators" do
    conn =
      stub_connection(fn query, params, opts ->
        assert query =~ "INFORMATION_SCHEMA.TABLES"
        assert params == ["dbo"]
        assert opts == [prepared: false]

        {:ok, %{rows: [["orders"], ["users"]], columns: ["TABLE_NAME"]}}
      end)

    assert {:ok, ["orders", "users"]} = SelectoDBMSSQL.Adapter.list_tables(conn, schema: "dbo")
  end

  test "mssql adapter introspects tables for selecto_mix generators" do
    conn =
      stub_connection(fn query, params, _opts ->
        cond do
          query =~ "INFORMATION_SCHEMA.COLUMNS" ->
            assert params == ["sales", "orders"]

            {:ok,
             %{
               rows: [
                 ["id", "int", "NO", nil, nil, 10, 0, nil, 1],
                 ["account_id", "int", "NO", nil, nil, 10, 0, nil, 2],
                 ["inserted_at", "datetime2", "YES", nil, nil, nil, nil, 6, 3]
               ],
               columns: []
             }}

          query =~ "CONSTRAINT_TYPE = 'PRIMARY KEY'" ->
            {:ok, %{rows: [["id"]], columns: []}}

          query =~ "FROM sys.foreign_keys AS fk" and query =~ "SCHEMA_NAME(parent_tbl.schema_id)" ->
            {:ok,
             %{
               rows: [["orders_account_id_fkey", "account_id", "sales", "accounts", "id"]],
               columns: []
             }}

          true ->
            flunk("unexpected query: #{query}")
        end
      end)

    assert {:ok, metadata} =
             SelectoDBMSSQL.Adapter.introspect_table(conn, "orders",
               schema: "sales",
               expand: false
             )

    assert metadata.table_name == "orders"
    assert metadata.schema == "sales"
    assert metadata.fields == [:id, :account_id, :inserted_at]
    assert metadata.field_types.id == :integer
    assert metadata.field_types.inserted_at == :naive_datetime
    assert metadata.primary_key == :id
    assert metadata.source == :mssql

    assert metadata.associations == %{
             account: %{
               association_type: :belongs_to,
               constraint_name: "orders_account_id_fkey",
               field: :account,
               is_through: false,
               join_type: :inner,
               owner_key: :account_id,
               queryable: :accounts,
               related_key: :id,
               related_module_name: "Account",
               related_schema: "Account",
               related_table: "accounts",
               type: :belongs_to
             }
           }
  end

  test "adapter normalizes date and time tuples in result rows" do
    result = %{
      rows: [
        [
          {{2026, 3, 15}, {14, 30, 45, 123_456}},
          {{2026, 3, 16}, {9, 5, 7}},
          {2026, 3, 17},
          {8, 9, 10}
        ]
      ],
      columns: ["placed_at", "processed_at", "ship_on", "ship_time"]
    }

    normalized = normalize_result(result)

    assert normalized.rows == [
             [
               "2026-03-15T14:30:45.123456",
               "2026-03-16T09:05:07",
               "2026-03-17",
               "08:09:10"
             ]
           ]

    assert normalized.columns == ["placed_at", "processed_at", "ship_on", "ship_time"]
  end

  test "adapter normalizes tuple rows and preserves scalar values" do
    result = %{
      rows: [
        {1, "SO-1001", {{2026, 3, 15}, {14, 30, 45, 0}}, true, nil}
      ],
      columns: ["id", "order_number", "placed_at", "active", "notes"]
    }

    normalized = normalize_result(result)

    assert normalized.rows == [[1, "SO-1001", "2026-03-15T14:30:45.000000", true, nil]]
    assert normalized.columns == ["id", "order_number", "placed_at", "active", "notes"]
  end

  test "mssql rollup keeps ISO syntax without NULLS FIRST ordering" do
    selecto =
      sales_domain()
      |> Selecto.configure(:mock_connection, adapter: SelectoDBMSSQL.Adapter, validate: false)
      |> Selecto.select(["region", {:sum, "amount"}])
      |> Selecto.group_by(rollup: ["region"])
      |> Selecto.order_by([{"region", :asc}])

    {sql, _aliases, _params} = Selecto.gen_sql(selecto, [])
    normalized_sql = String.replace(sql, ~r/\s+/, " ")

    assert String.contains?(
             String.downcase(normalized_sql),
             "group by rollup( selecto_root.region )"
           )

    refute String.contains?(String.downcase(normalized_sql), "nulls")
  end

  defp sales_domain do
    %{
      source: %{
        source_table: "sales",
        primary_key: :id,
        fields: [:id, :region, :amount],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          region: %{type: :string},
          amount: %{type: :decimal}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      name: "Sales"
    }
  end

  defp normalize_result(result) do
    apply(SelectoDBMSSQL.Adapter, :normalize_result, [result])
  end

  defp stub_connection(query_fun), do: %{query_fun: query_fun}
end
