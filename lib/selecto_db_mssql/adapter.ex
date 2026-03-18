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
      :requires_order_for_pagination,
      :schema_introspection
    ]
  end

  @impl true
  def list_tables(connection, opts \\ []) do
    schema = normalize_schema(opts)

    query = """
    SELECT TABLE_NAME
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = @p1
      AND TABLE_TYPE = 'BASE TABLE'
    ORDER BY TABLE_NAME
    """

    case introspection_query(connection, query, [schema]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [table_name] -> table_name end)}
      {:error, reason} -> {:error, {:query_failed, reason}}
    end
  end

  @impl true
  def introspect_table(connection, table_name, opts \\ []) do
    schema = normalize_schema(opts)
    include_associations = Keyword.get(opts, :include_associations, true)
    expand = Keyword.get(opts, :expand, false)

    with {:ok, columns} <- get_columns(connection, table_name, schema),
         {:ok, primary_key} <- get_primary_key(connection, table_name, schema),
         {:ok, foreign_keys} <- get_foreign_keys(connection, table_name, schema) do
      fields = Enum.map(columns, & &1.column_name)

      field_types =
        Enum.into(columns, %{}, fn column ->
          {column.column_name, map_mssql_type(column.data_type)}
        end)

      associations =
        cond do
          not include_associations ->
            %{}

          expand ->
            case build_expanded_associations(connection, table_name, schema, primary_key) do
              {:ok, expanded_associations} -> expanded_associations
              {:error, _reason} -> build_associations(foreign_keys)
            end

          true ->
            build_associations(foreign_keys)
        end

      column_metadata =
        Enum.into(columns, %{}, fn column ->
          {column.column_name,
           %{
             type: Map.get(field_types, column.column_name),
             nullable: column.is_nullable == "YES",
             default: column.column_default,
             max_length: column.character_maximum_length,
             precision: column.numeric_precision || column.datetime_precision,
             scale: column.numeric_scale
           }}
        end)

      {:ok,
       %{
         table_name: table_name,
         schema: schema,
         fields: fields,
         field_types: field_types,
         primary_key: primary_key,
         associations: associations,
         columns: column_metadata,
         source: :mssql
       }}
    end
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

  defp normalize_schema(opts) do
    case Keyword.get(opts, :schema) do
      nil -> "dbo"
      "" -> "dbo"
      "public" -> "dbo"
      schema -> schema
    end
  end

  defp introspection_query(%{query_fun: query_fun}, query, params)
       when is_function(query_fun, 3) do
    query_fun.(query, params, prepared: false)
  end

  defp introspection_query(connection, query, params) do
    execute(connection, query, params, prepared: false)
  end

  defp normalize_query(query) when is_binary(query), do: query
  defp normalize_query(query), do: IO.iodata_to_binary(query)

  defp get_columns(connection, table_name, schema) do
    query = """
    SELECT
      COLUMN_NAME,
      DATA_TYPE,
      IS_NULLABLE,
      COLUMN_DEFAULT,
      CHARACTER_MAXIMUM_LENGTH,
      NUMERIC_PRECISION,
      NUMERIC_SCALE,
      DATETIME_PRECISION,
      ORDINAL_POSITION
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = @p1 AND TABLE_NAME = @p2
    ORDER BY ORDINAL_POSITION
    """

    case introspection_query(connection, query, [schema, table_name]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [
                             column_name,
                             data_type,
                             is_nullable,
                             column_default,
                             max_length,
                             precision,
                             scale,
                             datetime_precision,
                             _ordinal_position
                           ] ->
           %{
             column_name: String.to_atom(column_name),
             data_type: data_type,
             is_nullable: is_nullable,
             column_default: column_default,
             character_maximum_length: max_length,
             numeric_precision: precision,
             numeric_scale: scale,
             datetime_precision: datetime_precision
           }
         end)}

      {:error, reason} ->
        {:error, {:columns_query_failed, reason}}
    end
  end

  defp get_primary_key(connection, table_name, schema) do
    query = """
    SELECT KU.COLUMN_NAME
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS AS TC
    JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS KU
      ON TC.CONSTRAINT_NAME = KU.CONSTRAINT_NAME
      AND TC.TABLE_SCHEMA = KU.TABLE_SCHEMA
      AND TC.TABLE_NAME = KU.TABLE_NAME
    WHERE TC.CONSTRAINT_TYPE = 'PRIMARY KEY'
      AND TC.TABLE_SCHEMA = @p1
      AND TC.TABLE_NAME = @p2
    ORDER BY KU.ORDINAL_POSITION
    """

    case introspection_query(connection, query, [schema, table_name]) do
      {:ok, %{rows: []}} -> {:ok, nil}
      {:ok, %{rows: [[single_key]]}} -> {:ok, String.to_atom(single_key)}
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [key] -> String.to_atom(key) end)}
      {:error, reason} -> {:error, {:primary_key_query_failed, reason}}
    end
  end

  defp get_foreign_keys(connection, table_name, schema) do
    query = """
    SELECT
      fk.name AS constraint_name,
      parent_col.name AS column_name,
      SCHEMA_NAME(ref_tbl.schema_id) AS foreign_table_schema,
      ref_tbl.name AS foreign_table_name,
      ref_col.name AS foreign_column_name
    FROM sys.foreign_keys AS fk
    JOIN sys.foreign_key_columns AS fkc
      ON fk.object_id = fkc.constraint_object_id
    JOIN sys.tables AS parent_tbl
      ON fk.parent_object_id = parent_tbl.object_id
    JOIN sys.columns AS parent_col
      ON fkc.parent_object_id = parent_col.object_id
      AND fkc.parent_column_id = parent_col.column_id
    JOIN sys.tables AS ref_tbl
      ON fk.referenced_object_id = ref_tbl.object_id
    JOIN sys.columns AS ref_col
      ON fkc.referenced_object_id = ref_col.object_id
      AND fkc.referenced_column_id = ref_col.column_id
    WHERE SCHEMA_NAME(parent_tbl.schema_id) = @p1
      AND parent_tbl.name = @p2
    ORDER BY fk.name, fkc.constraint_column_id
    """

    case introspection_query(connection, query, [schema, table_name]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [
                             constraint_name,
                             column_name,
                             foreign_schema,
                             foreign_table,
                             foreign_col
                           ] ->
           %{
             constraint_name: constraint_name,
             column_name: String.to_atom(column_name),
             foreign_table_schema: foreign_schema,
             foreign_table_name: foreign_table,
             foreign_column_name: String.to_atom(foreign_col)
           }
         end)}

      {:error, reason} ->
        {:error, {:foreign_keys_query_failed, reason}}
    end
  end

  defp get_reverse_foreign_keys(connection, table_name, schema) do
    query = """
    SELECT
      parent_tbl.name AS referencing_table,
      parent_col.name AS referencing_column,
      ref_col.name AS referenced_column,
      fk.name AS constraint_name
    FROM sys.foreign_keys AS fk
    JOIN sys.foreign_key_columns AS fkc
      ON fk.object_id = fkc.constraint_object_id
    JOIN sys.tables AS parent_tbl
      ON fk.parent_object_id = parent_tbl.object_id
    JOIN sys.columns AS parent_col
      ON fkc.parent_object_id = parent_col.object_id
      AND fkc.parent_column_id = parent_col.column_id
    JOIN sys.tables AS ref_tbl
      ON fk.referenced_object_id = ref_tbl.object_id
    JOIN sys.columns AS ref_col
      ON fkc.referenced_object_id = ref_col.object_id
      AND fkc.referenced_column_id = ref_col.column_id
    WHERE SCHEMA_NAME(ref_tbl.schema_id) = @p1
      AND ref_tbl.name = @p2
    ORDER BY parent_tbl.name, fk.name, fkc.constraint_column_id
    """

    case introspection_query(connection, query, [schema, table_name]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [
                             referencing_table,
                             referencing_column,
                             referenced_column,
                             constraint_name
                           ] ->
           %{
             referencing_table: referencing_table,
             referencing_column: String.to_atom(referencing_column),
             referenced_column: String.to_atom(referenced_column),
             constraint_name: constraint_name
           }
         end)}

      {:error, reason} ->
        {:error, {:reverse_foreign_keys_query_failed, reason}}
    end
  end

  defp normalize_params(params) when is_list(params) do
    params
    |> Enum.with_index(1)
    |> Enum.map(fn
      {%Tds.Parameter{} = parameter, _index} -> parameter
      {value, index} -> %Tds.Parameter{name: "@p#{index}", value: value}
    end)
  end

  defp normalize_params(_params), do: []

  defp build_associations(foreign_keys) do
    Enum.into(foreign_keys, %{}, fn foreign_key ->
      association_name =
        foreign_key.column_name
        |> Atom.to_string()
        |> String.replace_suffix("_id", "")
        |> String.to_atom()

      related_module_name = table_name_to_module(foreign_key.foreign_table_name)

      {association_name,
       %{
         type: :belongs_to,
         association_type: :belongs_to,
         related_schema: related_module_name,
         related_module_name: related_module_name,
         related_table: foreign_key.foreign_table_name,
         queryable: String.to_atom(foreign_key.foreign_table_name),
         field: association_name,
         owner_key: foreign_key.column_name,
         related_key: foreign_key.foreign_column_name,
         join_type: :inner,
         is_through: false,
         constraint_name: foreign_key.constraint_name
       }}
    end)
  end

  defp build_expanded_associations(connection, table_name, schema, primary_key) do
    with {:ok, foreign_keys} <- get_foreign_keys(connection, table_name, schema),
         {:ok, reverse_foreign_keys} <- get_reverse_foreign_keys(connection, table_name, schema),
         {:ok, junction_tables} <- detect_junction_tables(connection, schema) do
      belongs_to = build_associations(foreign_keys)

      primary_key_field = normalize_primary_key(primary_key)

      has_many =
        Enum.into(reverse_foreign_keys, %{}, fn reverse_foreign_key ->
          association_name = String.to_atom(reverse_foreign_key.referencing_table)
          related_module_name = table_name_to_module(reverse_foreign_key.referencing_table)

          {association_name,
           %{
             type: :has_many,
             association_type: :has_many,
             related_schema: related_module_name,
             related_module_name: related_module_name,
             related_table: reverse_foreign_key.referencing_table,
             queryable: String.to_atom(reverse_foreign_key.referencing_table),
             field: association_name,
             owner_key: primary_key_field,
             related_key: reverse_foreign_key.referencing_column,
             join_type: :left,
             is_through: false,
             constraint_name: reverse_foreign_key.constraint_name
           }}
        end)

      many_to_many =
        junction_tables
        |> Enum.filter(fn junction -> table_name in junction.tables end)
        |> Enum.flat_map(fn junction ->
          {this_foreign_keys, other_foreign_keys} =
            Enum.split_with(junction.foreign_keys, fn foreign_key ->
              foreign_key.foreign_table_name == table_name
            end)

          Enum.map(other_foreign_keys, fn other_foreign_key ->
            association_name = String.to_atom(other_foreign_key.foreign_table_name)
            related_module_name = table_name_to_module(other_foreign_key.foreign_table_name)

            owner_foreign_key =
              case this_foreign_keys do
                [foreign_key | _] -> foreign_key.column_name
                _ -> primary_key_field
              end

            {association_name,
             %{
               type: :many_to_many,
               association_type: :many_to_many,
               related_schema: related_module_name,
               related_module_name: related_module_name,
               related_table: other_foreign_key.foreign_table_name,
               queryable: String.to_atom(other_foreign_key.foreign_table_name),
               field: association_name,
               owner_key: primary_key_field,
               related_key: other_foreign_key.foreign_column_name,
               join_type: :left,
               is_through: false,
               join_through: junction.table,
               join_keys: [
                 {owner_foreign_key, primary_key_field},
                 {other_foreign_key.column_name, other_foreign_key.foreign_column_name}
               ]
             }}
          end)
        end)
        |> Enum.into(%{})

      {:ok, belongs_to |> Map.merge(has_many) |> Map.merge(many_to_many)}
    end
  end

  defp detect_junction_tables(connection, schema) do
    with {:ok, tables} <- list_tables(connection, schema: schema) do
      junction_tables =
        Enum.flat_map(tables, fn table ->
          case analyze_junction_table(connection, table, schema) do
            {:ok, junction_table} -> [junction_table]
            _ -> []
          end
        end)

      {:ok, junction_tables}
    end
  end

  defp analyze_junction_table(connection, table, schema) do
    with {:ok, columns} <- get_columns(connection, table, schema),
         {:ok, foreign_keys} <- get_foreign_keys(connection, table, schema),
         {:ok, primary_key} <- get_primary_key(connection, table, schema),
         true <- junction_table?(columns, foreign_keys) do
      primary_key_fields = normalize_primary_keys(primary_key)
      foreign_key_fields = Enum.map(foreign_keys, & &1.column_name)
      all_fields = Enum.map(columns, & &1.column_name)

      {:ok,
       %{
         table: table,
         foreign_keys: foreign_keys,
         primary_key: primary_key,
         extra_columns: all_fields -- Enum.uniq(primary_key_fields ++ foreign_key_fields),
         tables: Enum.map(foreign_keys, & &1.foreign_table_name)
       }}
    else
      false -> {:error, :not_junction_table}
      {:error, reason} -> {:error, reason}
    end
  end

  defp junction_table?(columns, foreign_keys) do
    foreign_key_fields = MapSet.new(Enum.map(foreign_keys, & &1.column_name))

    data_fields =
      columns
      |> Enum.map(& &1.column_name)
      |> Enum.reject(fn field ->
        field_name = Atom.to_string(field)

        field_name in ["id", "inserted_at", "updated_at", "created_at"] or
          String.ends_with?(field_name, "_at")
      end)

    length(foreign_keys) == 2 and Enum.all?(data_fields, &MapSet.member?(foreign_key_fields, &1))
  end

  defp normalize_primary_key([primary_key | _]), do: primary_key
  defp normalize_primary_key(primary_key) when is_atom(primary_key), do: primary_key
  defp normalize_primary_key(_), do: :id

  defp normalize_primary_keys(primary_key) when is_list(primary_key), do: primary_key
  defp normalize_primary_keys(primary_key) when is_atom(primary_key), do: [primary_key]
  defp normalize_primary_keys(_), do: []

  defp map_mssql_type(data_type) do
    case data_type do
      type when type in ["tinyint", "smallint", "int", "bigint"] ->
        :integer

      type when type in ["decimal", "numeric", "money", "smallmoney"] ->
        :decimal

      type when type in ["float", "real"] ->
        :float

      type when type in ["char", "nchar", "varchar", "nvarchar", "text", "ntext", "xml"] ->
        :string

      "bit" ->
        :boolean

      "date" ->
        :date

      "time" ->
        :time

      "datetimeoffset" ->
        :utc_datetime

      type when type in ["datetime", "datetime2", "smalldatetime"] ->
        :naive_datetime

      "uniqueidentifier" ->
        :binary_id

      type when type in ["binary", "varbinary", "image", "rowversion", "timestamp"] ->
        :binary

      _ ->
        :string
    end
  end

  defp table_name_to_module(table_name) when is_binary(table_name) do
    table_name
    |> singularize()
    |> Macro.camelize()
  end

  defp singularize(word) do
    cond do
      String.ends_with?(word, "ies") ->
        String.replace_suffix(word, "ies", "y")

      String.ends_with?(word, "sses") ->
        String.replace_suffix(word, "sses", "ss")

      String.ends_with?(word, "ses") ->
        String.replace_suffix(word, "ses", "s")

      String.ends_with?(word, "s") and not String.ends_with?(word, "ss") ->
        String.replace_suffix(word, "s", "")

      true ->
        word
    end
  end

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
