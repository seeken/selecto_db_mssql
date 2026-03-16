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
end
