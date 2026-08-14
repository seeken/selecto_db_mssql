defmodule SelectoDBMSSQL.Dialect do
  @moduledoc false

  @behaviour Selecto.DB.Dialect

  alias Selecto.Dialect.Collection.Operation, as: CollectionOperation
  alias Selecto.Dialect.DateTime.Operation, as: DateTimeOperation
  alias Selecto.Dialect.Predicate.Comparison
  alias Selecto.Dialect.TableFunction.Join, as: TableFunctionJoin
  alias Selecto.Dialect.Window.FrameBoundary

  @impl true
  def render_datetime_operation(%DateTimeOperation{operation: :format} = operation, _selecto) do
    if temporal_conversion_requested?(operation.options) do
      unsupported_datetime(operation)
    else
      {:ok,
       SelectoDBMSSQL.Adapter.format_datetime(
         operation.expression,
         Map.fetch!(operation.options, :format)
       )}
    end
  end

  def render_datetime_operation(%DateTimeOperation{} = operation, _selecto),
    do: unsupported_datetime(operation)

  @impl true
  def render_comparison(%Comparison{} = comparison, _selecto) do
    operator = if comparison.operation == :case_insensitive_not_like, do: "NOT LIKE", else: "LIKE"
    {:ok, ["LOWER(", comparison.left, ") ", operator, " LOWER(", comparison.right, ")"]}
  end

  alias Selecto.Dialect.Json.{
    ArrayContains,
    ArrayContainsAll,
    Contains,
    Extraction,
    KeyExists,
    Operation
  }

  @impl true
  def render_json_extraction(%Extraction{} = fragment, _selecto) do
    function = if fragment.as_text, do: "JSON_VALUE", else: "JSON_QUERY"
    extraction = [function, "(", column_ref(fragment), ", '", json_path(fragment.path), "')"]
    {:ok, cast_json(extraction, fragment.cast)}
  end

  @impl true
  def render_json_contains(%Contains{value: value} = fragment, _selecto) when is_map(value) do
    clauses =
      value
      |> flatten_object([])
      |> Enum.map(fn {path, path_value} ->
        [
          "JSON_VALUE(",
          column_ref(fragment),
          ", '",
          json_path(path),
          "') = '",
          escape_literal(path_value),
          "'"
        ]
      end)
      |> Enum.intersperse(" AND ")

    {:ok, clauses}
  end

  def render_json_contains(%Contains{value: value}, _selecto) do
    {:error,
     Selecto.Error.validation_error("SQL Server JSON containment supports only objects", %{
       value: value,
       unsupported_feature: :json_contains
     })}
  end

  @impl true
  def render_json_key_exists(%KeyExists{} = fragment, _selecto) do
    path = json_path(fragment.path)
    column = column_ref(fragment)

    {:ok,
     [
       "(JSON_QUERY(",
       column,
       ", '",
       path,
       "') IS NOT NULL OR JSON_VALUE(",
       column,
       ", '",
       path,
       "') IS NOT NULL)"
     ]}
  end

  @impl true
  def render_json_array_contains(%ArrayContains{value: values} = fragment, selecto)
      when is_list(values) do
    values
    |> Enum.map(fn value ->
      render_json_array_contains(%{fragment | value: value}, selecto) |> elem(1)
    end)
    |> Enum.intersperse(" OR ")
    |> then(&{:ok, &1})
  end

  def render_json_array_contains(%ArrayContains{} = fragment, _selecto) do
    {:ok,
     [
       "EXISTS (SELECT 1 FROM OPENJSON(",
       column_ref(fragment),
       ", '",
       json_path(fragment.path),
       "') WHERE value = '",
       escape_literal(fragment.value),
       "')"
     ]}
  end

  @impl true
  def render_json_array_contains_all(%ArrayContainsAll{} = fragment, selecto) do
    fragment.values
    |> Enum.map(fn value ->
      render_json_array_contains(
        %ArrayContains{
          column: fragment.column,
          path: fragment.path,
          value: value,
          table_alias: fragment.table_alias
        },
        selecto
      )
      |> elem(1)
    end)
    |> Enum.intersperse(" AND ")
    |> then(&{:ok, &1})
  end

  @impl true
  def render_json_operation(%Operation{} = operation, selecto) do
    case operation.operation do
      kind when kind in [:json_extract, :json_extract_path] ->
        operation_extraction(operation, false, selecto)

      kind when kind in [:json_extract_text, :json_extract_path_text] ->
        operation_extraction(operation, true, selecto)

      :json_contains ->
        render_json_contains(operation_contains(operation), selecto)

      kind when kind in [:json_exists, :json_path_exists] ->
        render_json_key_exists(operation_key_exists(operation), selecto)

      :json_empty_array ->
        {:ok, "'[]'"}

      _operation ->
        {:error,
         Selecto.Error.validation_error("SQL Server does not support this JSON operation", %{
           operation: operation.operation,
           unsupported_feature: :json_operation
         })}
    end
  end

  @impl true
  def render_collection_operation(%CollectionOperation{} = operation, _selecto) do
    case operation.operation do
      :string_agg when not operation.distinct ->
        delimiter = Map.get(operation.options, :delimiter, ",")

        within_group =
          case operation.order_by do
            order_by when order_by in [nil, []] ->
              []

            order_by ->
              [
                " WITHIN GROUP (ORDER BY ",
                order_by
                |> Enum.map(fn {expression, direction} ->
                  [expression, " ", direction |> Atom.to_string() |> String.upcase()]
                end)
                |> Enum.intersperse(", "),
                ")"
              ]
          end

        {:ok,
         {[
            "STRING_AGG(",
            operation.column,
            ", ",
            {:param, delimiter},
            ")",
            within_group
          ], [delimiter]}}

      unsupported ->
        {:error,
         Selecto.Error.validation_error(
           "SQL Server does not support this collection operation",
           %{operation: unsupported, unsupported_feature: :collection_operation}
         )}
    end
  end

  @impl true
  def render_table_function_join(
        %TableFunctionJoin{ordinality_alias: ordinality},
        _selecto
      )
      when not is_nil(ordinality) do
    {:error,
     Selecto.Error.validation_error("SQL Server APPLY does not support WITH ORDINALITY", %{
       unsupported_feature: :table_function_ordinality
     })}
  end

  def render_table_function_join(%TableFunctionJoin{} = join, _selecto) do
    case join.join_type do
      type when type in [:cross, :inner] ->
        {:ok,
         [
           "CROSS APPLY ",
           join.source_sql,
           " AS ",
           SelectoDBMSSQL.Adapter.quote_identifier(join.alias)
         ]}

      :left ->
        {:ok,
         [
           "OUTER APPLY ",
           join.source_sql,
           " AS ",
           SelectoDBMSSQL.Adapter.quote_identifier(join.alias)
         ]}

      type ->
        {:error,
         Selecto.Error.validation_error(
           "MSSQL APPLY only supports :inner and :left lateral joins",
           %{join_type: type, unsupported_feature: :table_function_join}
         )}
    end
  end

  @impl true
  def render_window_frame_boundary(%FrameBoundary{} = boundary, _selecto) do
    {:error,
     Selecto.Error.validation_error("MSSQL window frames do not support interval boundaries", %{
       adapter: :mssql,
       frame_boundary: boundary,
       unsupported_feature: :window_interval_frame
     })}
  end

  defp operation_extraction(operation, as_text, selecto) do
    render_json_extraction(
      %Extraction{
        column: operation.column,
        path: parse_operation_path(operation.path),
        as_text: as_text,
        table_alias: operation.table_alias
      },
      selecto
    )
  end

  defp operation_contains(operation) do
    %Contains{
      column: operation.column,
      value: operation.value,
      table_alias: operation.table_alias
    }
  end

  defp operation_key_exists(operation) do
    %KeyExists{
      column: operation.column,
      path: parse_operation_path(operation.path),
      table_alias: operation.table_alias
    }
  end

  defp parse_operation_path(nil), do: []

  defp parse_operation_path(path) do
    path
    |> String.replace_prefix("$.", "")
    |> String.split(~r/[\.\[\]]/, trim: true)
  end

  defp column_ref(%{column: column, table_alias: nil}),
    do: SelectoDBMSSQL.Adapter.quote_identifier(column)

  defp column_ref(%{column: column, table_alias: table_alias}) do
    [
      SelectoDBMSSQL.Adapter.quote_identifier(table_alias),
      ".",
      SelectoDBMSSQL.Adapter.quote_identifier(column)
    ]
  end

  defp json_path(path) do
    path
    |> Enum.reduce("$", fn segment, acc ->
      case Integer.parse(to_string(segment)) do
        {index, ""} -> acc <> "[#{index}]"
        _ -> acc <> "." <> safe_segment!(segment)
      end
    end)
    |> escape_literal()
  end

  defp safe_segment!(segment) do
    segment = to_string(segment)

    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, segment),
      do: segment,
      else: raise(ArgumentError, "invalid JSON path segment: #{inspect(segment)}")
  end

  defp flatten_object(map, prefix) do
    Enum.flat_map(map, fn
      {key, nested} when is_map(nested) ->
        flatten_object(nested, prefix ++ [to_string(key)])

      {key, value} when is_list(value) ->
        raise Selecto.Error.to_exception(
                Selecto.Error.validation_error(
                  "SQL Server JSON containment does not support nested arrays",
                  %{path: prefix ++ [to_string(key)]}
                )
              )

      {key, value} ->
        [{prefix ++ [to_string(key)], value}]
    end)
  end

  defp cast_json(extraction, nil), do: extraction
  defp cast_json(extraction, :integer), do: ["CAST(", extraction, " AS int)"]
  defp cast_json(extraction, :decimal), do: ["CAST(", extraction, " AS decimal(38, 10))"]
  defp cast_json(extraction, :float), do: ["CAST(", extraction, " AS float)"]
  defp cast_json(extraction, :boolean), do: ["CAST(", extraction, " AS bit)"]
  defp cast_json(extraction, :date), do: ["CAST(", extraction, " AS date)"]
  defp cast_json(extraction, :datetime), do: ["CAST(", extraction, " AS datetime2)"]
  defp cast_json(extraction, :utc_datetime), do: ["CAST(", extraction, " AS datetimeoffset)"]

  defp cast_json(_extraction, cast),
    do: raise(ArgumentError, "unsupported SQL Server JSON cast: #{inspect(cast)}")

  defp temporal_conversion_requested?(options) do
    Map.get(options, :epoch_storage) not in [nil, false] or
      Map.get(options, :timezone) not in [nil, ""]
  end

  defp unsupported_datetime(operation) do
    {:error,
     Selecto.Error.validation_error("SQL Server does not support this datetime operation", %{
       operation: operation.operation,
       unsupported_feature: :datetime_operation
     })}
  end

  defp escape_literal(value), do: value |> to_string() |> String.replace("'", "''")
end
