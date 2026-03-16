defmodule SelectoDBMSSQL.Adapter do
  @moduledoc """
  Microsoft SQL Server adapter for Selecto backed by `Tds`.
  """

  @behaviour Selecto.DB.Adapter

  @missing_dependency {:adapter_dependency_missing, :tds}

  @impl true
  def name, do: :mssql

  @impl true
  def connect(connection) when is_pid(connection) or is_atom(connection), do: {:ok, connection}
  def connect(opts) when is_map(opts), do: connect(Map.to_list(opts))

  def connect(opts) when is_list(opts) do
    if dependency_available?() do
      case Tds.start_link(opts) do
        {:ok, conn} -> {:ok, conn}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, @missing_dependency}
    end
  end

  def connect(other), do: {:error, {:invalid_connection_options, other}}

  @impl true
  def execute(connection, query, params, opts) do
    if is_map(connection) and Map.has_key?(connection, :adapter) and
         Map.has_key?(connection, :connection) do
      execute_direct(Map.get(connection, :connection), query, params, opts)
    else
      execute_direct(connection, query, params, opts)
    end
  end

  defp execute_direct(connection, query, params, opts) do
    if dependency_available?() do
      case Tds.query(connection, normalize_query(query), normalize_params(params), opts) do
        {:ok, result} -> {:ok, normalize_result(result)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, @missing_dependency}
    end
  end

  @impl true
  def placeholder(index), do: ["@p", Integer.to_string(index)]

  @impl true
  def quote_identifier(identifier) when is_binary(identifier) do
    escaped = String.replace(identifier, "]", "]]")
    "[#{escaped}]"
  end

  def quote_identifier(identifier), do: identifier |> to_string() |> quote_identifier()

  @impl true
  def supports?(feature) do
    feature in [
      :cte,
      :window_functions,
      :transactions,
      :rollup,
      :offset_fetch_pagination,
      :requires_order_for_pagination
    ]
  end

  @impl true
  def format_datetime(sel_iodata, "YYYY-MM-DD") do
    ["CONVERT(varchar(10), CAST(", sel_iodata, " AS datetime2), 23)"]
  end

  def format_datetime(sel_iodata, "YYYY-MM") do
    ["LEFT(CONVERT(varchar(10), CAST(", sel_iodata, " AS datetime2), 23), 7)"]
  end

  def format_datetime(sel_iodata, "YYYY") do
    ["FORMAT(CAST(", sel_iodata, " AS datetime2), 'yyyy')"]
  end

  def format_datetime(sel_iodata, "YYYY-WW") do
    [
      "CONCAT(FORMAT(CAST(",
      sel_iodata,
      " AS datetime2), 'yyyy'), '-', RIGHT('0' + CAST(DATEPART(ISO_WEEK, CAST(",
      sel_iodata,
      " AS datetime2)) AS varchar(2)), 2))"
    ]
  end

  def format_datetime(sel_iodata, "YYYY-Q") do
    [
      "CONCAT(FORMAT(CAST(",
      sel_iodata,
      " AS datetime2), 'yyyy'), '-', DATEPART(QUARTER, CAST(",
      sel_iodata,
      " AS datetime2)))"
    ]
  end

  def format_datetime(sel_iodata, "MM") do
    ["FORMAT(CAST(", sel_iodata, " AS datetime2), 'MM')"]
  end

  def format_datetime(sel_iodata, "DD") do
    ["FORMAT(CAST(", sel_iodata, " AS datetime2), 'dd')"]
  end

  def format_datetime(sel_iodata, "D") do
    ["CAST(DATEPART(WEEKDAY, CAST(", sel_iodata, " AS datetime2)) AS varchar(2))"]
  end

  def format_datetime(sel_iodata, "HH24") do
    ["FORMAT(CAST(", sel_iodata, " AS datetime2), 'HH')"]
  end

  def format_datetime(sel_iodata, _format) do
    ["CONVERT(varchar(33), CAST(", sel_iodata, " AS datetime2), 126)"]
  end

  defp dependency_available? do
    Code.ensure_loaded?(Tds) and function_exported?(Tds, :start_link, 1) and
      function_exported?(Tds, :query, 4)
  end

  defp normalize_query(query) when is_binary(query), do: query
  defp normalize_query(query), do: IO.iodata_to_binary(query)

  defp normalize_params(params) when is_list(params) do
    params
    |> Enum.with_index(1)
    |> Enum.map(fn
      {%Tds.Parameter{} = parameter, _index} -> parameter
      {value, index} -> %Tds.Parameter{name: "@p#{index}", value: value}
    end)
  end

  defp normalize_params(_params), do: []

  @doc false
  def normalize_result(%{rows: rows} = result) do
    columns =
      result
      |> Map.get(:columns, [])
      |> Enum.map(&normalize_column_name/1)

    %{
      rows: normalize_rows(rows || []),
      columns: columns
    }
  end

  defp normalize_rows(rows) when is_list(rows), do: Enum.map(rows, &normalize_row/1)
  defp normalize_rows(rows), do: rows

  defp normalize_row(row) when is_list(row), do: Enum.map(row, &normalize_value/1)

  defp normalize_row(row) when is_tuple(row),
    do: row |> Tuple.to_list() |> Enum.map(&normalize_value/1)

  defp normalize_row(row), do: normalize_value(row)

  defp normalize_value({{year, month, day}, {hour, minute, second, microsecond}}) do
    with {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second, normalize_microsecond(microsecond)),
         {:ok, naive_datetime} <- NaiveDateTime.new(date, time) do
      NaiveDateTime.to_iso8601(naive_datetime)
    else
      _ -> {{year, month, day}, {hour, minute, second, microsecond}}
    end
  end

  defp normalize_value({{year, month, day}, {hour, minute, second}}) do
    with {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second, {0, 0}),
         {:ok, naive_datetime} <- NaiveDateTime.new(date, time) do
      NaiveDateTime.to_iso8601(naive_datetime)
    else
      _ -> {{year, month, day}, {hour, minute, second}}
    end
  end

  defp normalize_value({year, month, day}) when is_integer(year) and year > 31 do
    case Date.new(year, month, day) do
      {:ok, date} -> Date.to_iso8601(date)
      _ -> {year, month, day}
    end
  end

  defp normalize_value({hour, minute, second})
       when is_integer(hour) and hour >= 0 and hour <= 23 do
    case Time.new(hour, minute, second, {0, 0}) do
      {:ok, time} -> Time.to_iso8601(time)
      _ -> {hour, minute, second}
    end
  end

  defp normalize_value(value), do: value

  defp normalize_microsecond(value) when is_integer(value) and value >= 0 and value < 1_000_000,
    do: {value, 6}

  defp normalize_microsecond(value) when is_integer(value) and value >= 1_000_000,
    do: {rem(value, 1_000_000), 6}

  defp normalize_microsecond(_value), do: {0, 0}

  defp normalize_column_name(%{name: name}) when is_binary(name), do: name
  defp normalize_column_name(name) when is_binary(name), do: name
  defp normalize_column_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_column_name(other), do: to_string(other)
end
