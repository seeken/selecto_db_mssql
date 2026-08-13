defmodule SelectoDBMSSQL.WriteExecutor do
  @moduledoc false

  alias Selecto.Write.{Batch, Command, Error, Graph, Preview, Result}
  alias Selecto.Write.Graph.Materializer
  alias SelectoDBMSSQL.{Adapter, WriteCompiler}

  def write_capabilities(connection) do
    %{
      protocol_version: Selecto.Write.Capabilities.protocol_version(),
      insert: true,
      update: true,
      upsert: true,
      delete: true,
      returning: true,
      generated_keys: :output,
      transactions: true,
      atomic_batch: true,
      write_graph: true,
      dialect: :mssql,
      server_version: server_version(connection),
      merge: true,
      merge_strategy: :holdlock
    }
  end

  def preview_write(_connection, %Command{} = command, opts),
    do: WriteCompiler.preview(command, opts)

  def preview_write(_connection, %Batch{} = batch, opts), do: WriteCompiler.preview(batch, opts)
  def preview_write(_connection, %Graph{} = graph, opts), do: preview_graph(graph, opts)
  def preview_write(_connection, write, _opts), do: invalid_write_input(write)

  def execute_write(connection, %Command{} = command, opts) do
    with :ok <- Command.validate(command) do
      with_transaction(connection, fn tx -> execute_command(tx, command, opts) end)
    end
  end

  def execute_write(connection, %Batch{} = batch, opts) do
    with :ok <- Batch.validate(batch) do
      with_transaction(connection, fn tx ->
        Enum.reduce_while(batch.commands, {:ok, []}, fn command, {:ok, results} ->
          case execute_command(tx, command, opts) do
            {:ok, result} -> {:cont, {:ok, results ++ [result]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
      end)
    end
  end

  def execute_write(connection, %Graph{} = graph, opts) do
    with :ok <- Graph.validate(graph) do
      with_transaction(connection, fn tx -> execute_graph(tx, graph, opts) end)
    end
  end

  def execute_write(_connection, write, _opts), do: invalid_write_input(write)

  def transaction(connection, fun, _opts) when is_function(fun, 1) do
    connection = resolve_connection(connection)

    case Tds.transaction(connection, fn tx ->
           case fun.(tx) do
             {:ok, result} -> result
             {:error, reason} -> Tds.rollback(tx, reason)
             result -> result
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp preview_graph(graph, opts) do
    graph.nodes
    |> Enum.reduce_while({:ok, [], %{}}, fn node, {:ok, statements, results} ->
      with {:ok, materialized} <- Materializer.materialize_node(node, results),
           {:ok, node_statements} <- preview_node(materialized, opts) do
        next_results = Map.merge(results, Materializer.symbolic_results(materialized))
        {:cont, {:ok, statements ++ node_statements, next_results}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, statements, _results} ->
        {:ok,
         %Preview{
           statements: statements,
           metadata: %{dialect: :mssql, atomic?: true, graph?: true, strategy: :ordered_merge}
         }}

      error ->
        error
    end
  end

  defp preview_node(node, opts) do
    row_results =
      node
      |> Materializer.symbolic_results()
      |> Map.new(fn {{_node_id, row_id}, result} -> {row_id, result} end)

    with {:ok, cleanup} <- Materializer.delete_missing_command(node, row_results) do
      commands = Enum.map(node.rows, & &1.command)
      commands = if cleanup, do: commands ++ [cleanup], else: commands

      map_commands(commands, &WriteCompiler.compile(&1, opts))
    end
  end

  defp execute_graph(connection, graph, opts) do
    graph.nodes
    |> Enum.reduce_while({:ok, %{}, 0, []}, fn node, {:ok, results, affected, strategies} ->
      with {:ok, materialized} <- Materializer.materialize_node(node, results),
           {:ok, node_results, node_affected} <- execute_node(connection, materialized, opts) do
        next_results =
          Map.merge(
            results,
            Map.new(node_results, fn {id, result} -> {{node.id, id}, result} end)
          )

        {:cont,
         {:ok, next_results, affected + node_affected,
          strategies ++ [{node.id, node_strategy(node)}]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results, affected, strategies} ->
        {:ok,
         %Result{
           operation: :graph,
           affected_rows: affected,
           rows: Materializer.root_rows(graph, results),
           metadata: %{dialect: :mssql, atomic?: true, node_strategies: Map.new(strategies)}
         }}

      error ->
        error
    end
  end

  defp execute_node(connection, node, opts) do
    with {:ok, row_results, affected} <- execute_rows(connection, node.rows, opts),
         {:ok, cleanup} <- Materializer.delete_missing_command(node, row_results),
         {:ok, cleanup_affected} <- execute_cleanup(connection, cleanup, opts) do
      {:ok, row_results, affected + cleanup_affected}
    end
  end

  defp execute_rows(connection, rows, opts) do
    Enum.reduce_while(rows, {:ok, %{}, 0}, fn row, {:ok, results, affected} ->
      case execute_command(connection, row.command, opts) do
        {:ok, result} ->
          {:cont, {:ok, Map.put(results, row.id, result), affected + result.affected_rows}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp execute_cleanup(_connection, nil, _opts), do: {:ok, 0}

  defp execute_cleanup(connection, command, opts) do
    case execute_command(connection, command, opts) do
      {:ok, result} -> {:ok, result.affected_rows}
      {:error, _} = error -> error
    end
  end

  defp execute_command(connection, command, opts) do
    with {:ok, statement} <- WriteCompiler.compile(command, opts),
         {:ok, query_result} <-
           Adapter.execute(connection, statement.text, statement.params, opts),
         {:ok, affected} <- enforce_cardinality(command, query_result) do
      {:ok,
       %Result{
         operation: command.operation,
         affected_rows: affected,
         rows: result_rows(query_result),
         metadata: %{dialect: :mssql, strategy: command_strategy(command)}
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, write_error(:execution_failed, reason)}
    end
  end

  defp enforce_cardinality(%Command{expected_cardinality: expected}, result) do
    affected = Map.get(result, :num_rows, length(Map.get(result, :rows, [])))

    if cardinality_matches?(affected, expected) do
      {:ok, affected}
    else
      {:error,
       Error.new(:cardinality_mismatch, "write affected an unexpected number of rows",
         details: %{expected: expected, actual: affected}
       )}
    end
  end

  defp cardinality_matches?(count, {:exactly, expected}), do: count == expected
  defp cardinality_matches?(count, {:at_most, expected}), do: count <= expected
  defp cardinality_matches?(count, {:at_least, expected}), do: count >= expected
  defp cardinality_matches?(count, {:between, minimum, maximum}), do: count in minimum..maximum
  defp cardinality_matches?(_count, :many), do: true

  defp result_rows(%{rows: rows, columns: columns}) do
    Enum.map(rows, fn row -> Map.new(Enum.zip(columns, row)) end)
  end

  defp with_transaction(connection, fun) do
    case transaction(connection, fun, []) do
      {:ok, result} -> {:ok, result}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, write_error(:transaction_failed, reason)}
    end
  end

  defp server_version(connection) do
    case Adapter.execute(
           connection,
           "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(128))",
           [],
           []
         ) do
      {:ok, %{rows: [[version] | _]}} -> to_string(version)
      _ -> nil
    end
  rescue
    _exception -> nil
  catch
    :exit, _reason -> nil
  end

  defp resolve_connection(%{adapter: _adapter, connection: connection}), do: connection
  defp resolve_connection(connection), do: connection

  defp command_strategy(%Command{operation: :upsert}), do: :merge_holdlock
  defp command_strategy(_command), do: :direct
  defp node_strategy(%{rows: rows}) when is_list(rows), do: :ordered_merge

  defp map_commands(commands, fun) do
    Enum.reduce_while(commands, {:ok, []}, fn command, {:ok, statements} ->
      case fun.(command) do
        {:ok, statement} -> {:cont, {:ok, statements ++ [statement]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp invalid_write_input(write) do
    {:error,
     Error.new(:invalid_command, "expected a portable write command, batch, or graph",
       details: %{actual: write}
     )}
  end

  defp write_error(type, reason),
    do: Error.adapter_failure(type, :mssql, reason, "SQL Server write failed")
end
