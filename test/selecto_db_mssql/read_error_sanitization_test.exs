defmodule SelectoDBMSSQL.ReadErrorSanitizationTest do
  use ExUnit.Case, async: false

  alias SelectoDBMSSQL.Adapter

  test "driver errors keep a stable category and drop server text" do
    duplicate = %Tds.Error{
      mssql: %{
        line_number: 1,
        number: 2627,
        msg_text:
          "Violation of UNIQUE KEY constraint 'uq_people'. Cannot insert duplicate key in " <>
            "object 'dbo.people'. The duplicate key value is (secret@example.test)."
      }
    }

    connection = %DBConnection.ConnectionError{
      message: "tcp connect (db.internal:1433): connection refused - :econnrefused"
    }

    assert %Selecto.Error{
             type: :query_error,
             query: nil,
             params: [],
             details: %{adapter: :mssql, category: :unique_violation, code: 2627}
           } = error = Adapter.normalize_error(duplicate)

    refute inspect(error) =~ "secret"
    refute inspect(error) =~ "people"

    assert %Selecto.Error{type: :connection_error, details: %{category: :connection_error}} =
             connection_error = Adapter.normalize_error(connection)

    refute inspect(connection_error) =~ "db.internal"

    for {number, text, category} <- [
          {547, "conflicted with the FOREIGN KEY constraint", :foreign_key_violation},
          {547, "conflicted with the CHECK constraint", :check_violation},
          {515, "Cannot insert the value NULL", :not_null_violation},
          {207, "Invalid column name", :database_error}
        ] do
      assert %Selecto.Error{details: %{category: ^category}} =
               Adapter.normalize_error(%Tds.Error{
                 mssql: %{line_number: 1, number: number, msg_text: text}
               })
    end
  end

  @tag :requires_db
  @tag :mssql
  test "read errors from SQL Server carry no values, names or SQL" do
    {:ok, conn} = Adapter.connect(connection_options())
    table = "dbo.selecto_sanitize_people_#{System.unique_integer([:positive])}"

    try do
      assert {:ok, _} =
               Adapter.execute(
                 conn,
                 "CREATE TABLE #{table} ([id] int PRIMARY KEY, [email] nvarchar(80) NOT NULL UNIQUE)",
                 [],
                 []
               )

      insert = "INSERT INTO #{table} ([id], [email]) VALUES (@p1, @p2)"
      assert {:ok, _} = Adapter.execute(conn, insert, [1, "secret-value@example.test"], [])

      assert {:error, duplicate} =
               Adapter.execute(conn, insert, [2, "secret-value@example.test"], [])

      assert {:error, unknown} =
               Adapter.execute(conn, "SELECT [secret_marker] FROM #{table}", [], [])

      for {reason, category} <- [{duplicate, :unique_violation}, {unknown, :database_error}] do
        error = Adapter.normalize_error(reason)
        rendered = inspect(error, limit: :infinity, printable_limit: :infinity)

        refute rendered =~ "selecto_sanitize_people"
        refute rendered =~ "secret"
        assert %Selecto.Error{type: :query_error, details: %{category: ^category}} = error
      end
    after
      Adapter.execute(conn, "DROP TABLE IF EXISTS #{table}", [], [])
      if Process.alive?(conn), do: GenServer.stop(conn)
    end
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
