defmodule SelectoDBMSSQL.SelectoComponentsSQLTest do
  use ExUnit.Case, async: true

  alias SelectoComponents.Form.ParamsState
  alias SelectoComponents.Views.Detail.QueryPagination

  defmodule CapabilityMSSQLAdapter do
    def name, do: :test_mssql

    def connect(parent) when is_pid(parent), do: {:ok, parent}

    def execute(parent, query, _params, _opts) when is_pid(parent) do
      send(parent, {:executed_sql, query})

      down = String.downcase(query)

      cond do
        String.contains?(down, "count(*) as total_rows") ->
          {:ok, %{rows: [[25]], columns: ["total_rows"]}}

        String.contains?(down, "selecto_root.id") ->
          {:ok,
           %{
             rows: [[100, "N100"], [101, "N101"], [102, "N102"], [103, "N103"], [104, "N104"]],
             columns: ["id", "name"]
           }}

        true ->
          {:ok,
           %{
             rows: [["USA", "Boston", 12, "SO-1001", 8]],
             columns: ["country", "city", "customer_id", "order_number", "count"]
           }}
      end
    end

    def supports?(:bounded_count_top), do: true
    def supports?(:derived_table_column_aliases), do: true
    def supports?(_feature), do: false
  end

  test "aggregate count query uses derived-table aliases when adapter requires them" do
    updated_socket = ParamsState.view_from_params(aggregate_params(), aggregate_socket())

    assert updated_socket.assigns.executed == true

    count_sql =
      collect_sql_messages()
      |> Enum.find(&String.contains?(String.downcase(&1), "count(*) as total_rows"))

    assert is_binary(count_sql)

    assert count_sql =~
             ~r/selecto_aggregate_count\s*\(agg_col_1, agg_col_2, agg_col_3, agg_col_4, agg_col_5\)/i

    refute count_sql =~ ~r/ limit /i
  end

  test "bounded detail count query uses TOP when adapter advertises bounded_count_top" do
    selecto = detail_selecto(["name"])

    {{:ok, {_rows, _columns, _aliases}, _metadata}, _updated_view_meta, _cache} =
      QueryPagination.execute(
        selecto,
        detail_params(),
        detail_view_meta(%{count_mode: "bounded"}),
        detail_socket()
      )

    count_sql =
      collect_sql_messages()
      |> Enum.find(&String.contains?(String.downcase(&1), "count(*) as total_rows"))

    assert is_binary(count_sql)
    assert count_sql =~ ~r/top\s*\(1000\)/i
    refute count_sql =~ ~r/limit\s+1000/i
  end

  defp aggregate_socket do
    selecto =
      aggregate_domain()
      |> Selecto.configure(self(), adapter: CapabilityMSSQLAdapter, validate: false)

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        selecto: selecto,
        current_scope: nil,
        sort_by: nil,
        detail_page_cache: nil,
        aggregate_page_cache: nil,
        views: [
          {:aggregate, SelectoComponents.Views.Aggregate, "Aggregate", %{drill_down: :detail}},
          {:detail, SelectoComponents.Views.Detail, "Detail", %{}},
          {:graph, SelectoComponents.Views.Graph, "Graph", %{}}
        ],
        view_config: %{
          view_mode: "aggregate",
          filters: [],
          views: %{
            aggregate: %{group_by: [], aggregate: [], per_page: "100", grid: false}
          }
        }
      }
    }
  end

  defp aggregate_params do
    %{
      "view_mode" => "aggregate",
      "group_by" => %{
        "k0" => %{"field" => "country", "index" => "0", "uuid" => "g0"},
        "k1" => %{"field" => "city", "index" => "1", "uuid" => "g1"},
        "k2" => %{"field" => "customer_id", "index" => "2", "uuid" => "g2"},
        "k3" => %{"field" => "order_number", "index" => "3", "uuid" => "g3"}
      },
      "aggregate" => %{
        "k0" => %{"field" => "id", "function" => "count", "index" => "0", "uuid" => "a0"}
      },
      "aggregate_per_page" => "100",
      "aggregate_grid" => "false"
    }
  end

  defp detail_selecto(selected) do
    domain = %{
      name: "DetailQueryPaginationTest",
      source: %{
        source_table: "users",
        primary_key: :id,
        fields: [:id, :name],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    domain
    |> Selecto.configure(self(), adapter: CapabilityMSSQLAdapter, validate: false)
    |> Selecto.select(selected)
  end

  defp detail_socket(cache \\ nil) do
    %{assigns: %{detail_page_cache: cache, sort_by: nil}}
  end

  defp detail_view_meta(overrides) do
    Map.merge(
      %{page: 0, per_page: 2, max_rows: "1000", count_mode: "bounded", subselect_configs: []},
      overrides
    )
  end

  defp detail_params(overrides \\ %{}) do
    Map.merge(%{"view_mode" => "detail", "selected" => %{}}, overrides)
  end

  defp collect_sql_messages(acc \\ []) do
    receive do
      {:executed_sql, query} ->
        collect_sql_messages([query | acc])
    after
      100 ->
        Enum.reverse(acc)
    end
  end

  defp aggregate_domain do
    %{
      name: "Aggregate Pagination Domain",
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :country, :city, :customer_id, :order_number],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          country: %{type: :string},
          city: %{type: :string},
          customer_id: %{type: :integer},
          order_number: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      filters: %{},
      default_selected: ["id"]
    }
  end
end
