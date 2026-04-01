defmodule SelectoDBMSSQL.UpdatoAdapterTest do
  use ExUnit.Case, async: true

  defmodule Item do
    use Ecto.Schema
    import Ecto.Changeset

    schema "items" do
      field(:name, :string)
      field(:status, :string)
      field(:sku, :string)
    end

    def changeset(item, attrs) do
      item
      |> cast(attrs, [:name, :status, :sku])
      |> validate_required([:name])
    end
  end

  defmodule FakeMSSQLRepo do
    def __adapter__, do: Ecto.Adapters.Tds

    def seed(records), do: Process.put(:fake_mssql_repo_records, records)

    def insert(%Ecto.Changeset{valid?: false} = changeset, _opts), do: {:error, changeset}

    def insert(%Ecto.Changeset{} = changeset, opts) do
      send(self(), {:repo_insert_opts, opts})

      record =
        changeset
        |> Ecto.Changeset.apply_changes()
        |> Map.put(:id, 100)

      {:ok, record}
    end

    def insert_all(schema, records, opts) do
      send(self(), {:repo_insert_all_opts, schema, records, opts})

      returned =
        case Keyword.get(opts, :returning) do
          nil ->
            nil

          _ ->
            Enum.with_index(records, 1)
            |> Enum.map(fn {record, id} -> Map.put(record, :id, id) end)
        end

      {length(records), returned}
    end

    def aggregate(_query, :count), do: length(records())
    def one(_query), do: List.first(records())
    def all(_query), do: records()
    def update(%Ecto.Changeset{valid?: false} = changeset, _opts), do: {:error, changeset}

    def update(%Ecto.Changeset{} = changeset, opts) do
      send(self(), {:repo_update_opts, opts})

      updated = Ecto.Changeset.apply_changes(changeset)

      records =
        Enum.map(records(), fn record ->
          if record.id == updated.id, do: updated, else: record
        end)

      seed(records)
      {:ok, updated}
    end

    def delete(%Item{} = record, opts) do
      send(self(), {:repo_delete_opts, opts})
      seed(Enum.reject(records(), &(&1.id == record.id)))
      {:ok, record}
    end

    defp records, do: Process.get(:fake_mssql_repo_records, [])
  end

  setup do
    FakeMSSQLRepo.seed([])
    :ok
  end

  test "mssql insert returning uses repo returning projection" do
    op =
      SelectoUpdato.new(domain())
      |> SelectoUpdato.insert(%{name: "Widget", status: "draft"})
      |> SelectoUpdato.returning(:all)

    assert {:ok, %Item{id: 100, name: "Widget", status: "draft"}} =
             SelectoUpdato.execute(op, FakeMSSQLRepo)

    assert_received {:repo_insert_opts, opts}
    assert opts[:returning] == true
  end

  test "mssql single update returns selected fields" do
    FakeMSSQLRepo.seed([
      %Item{id: 1, name: "Widget", status: "draft", sku: "SKU-1"}
    ])

    op =
      SelectoUpdato.new(domain())
      |> SelectoUpdato.filter({"id", 1})
      |> SelectoUpdato.update(%{status: "published"})
      |> SelectoUpdato.returning([:id, :status])

    assert {:ok, %{id: 1, status: "published"}} = SelectoUpdato.execute(op, FakeMSSQLRepo)

    assert_received {:repo_update_opts, opts}
    assert opts[:returning] == [:id, :status]
  end

  test "mssql bulk insert returns projected records" do
    op =
      SelectoUpdato.new(domain())
      |> SelectoUpdato.insert_all([
        %{name: "A", status: "draft", sku: "SKU-1"},
        %{name: "B", status: "published", sku: "SKU-2"}
      ])
      |> SelectoUpdato.returning([:id, :name])

    assert {:ok, %{inserted: 2, records: [%{id: 1, name: "A"}, %{id: 2, name: "B"}]}} =
             SelectoUpdato.execute(op, FakeMSSQLRepo)

    assert_received {:repo_insert_all_opts, Item, records, opts}

    assert records == [
             %{name: "A", status: "draft", sku: "SKU-1"},
             %{name: "B", status: "published", sku: "SKU-2"}
           ]

    assert opts[:returning] == [:id, :name]
  end

  test "mssql bulk update returns projected records" do
    FakeMSSQLRepo.seed([
      %Item{id: 1, name: "A", status: "draft", sku: "SKU-1"},
      %Item{id: 2, name: "B", status: "draft", sku: "SKU-2"}
    ])

    op =
      SelectoUpdato.new(domain())
      |> SelectoUpdato.filter({"status", "draft"})
      |> SelectoUpdato.update(%{status: "published"})
      |> SelectoUpdato.returning([:id, :status])

    assert {:ok,
            %{updated: 2, records: [%{id: 1, status: "published"}, %{id: 2, status: "published"}]}} =
             SelectoUpdato.execute(op, FakeMSSQLRepo)
  end

  test "mssql bulk delete returns projected records" do
    FakeMSSQLRepo.seed([
      %Item{id: 1, name: "A", status: "draft", sku: "SKU-1"},
      %Item{id: 2, name: "B", status: "draft", sku: "SKU-2"}
    ])

    op =
      SelectoUpdato.new(domain())
      |> SelectoUpdato.filter({"status", "draft"})
      |> SelectoUpdato.delete()
      |> SelectoUpdato.returning([:id, :name])
      |> SelectoUpdato.confirm_bulk_delete(true)

    assert {:ok, %{deleted: 2, records: [%{id: 1, name: "A"}, %{id: 2, name: "B"}]}} =
             SelectoUpdato.execute(op, FakeMSSQLRepo)

    assert_received {:repo_delete_opts, opts}
    assert opts[:returning] == [:id, :name]
  end

  test "mssql upsert keeps conflict options and returning projection" do
    op =
      SelectoUpdato.new(domain())
      |> SelectoUpdato.upsert(%{name: "Widget", status: "draft", sku: "SKU-1"})
      |> SelectoUpdato.conflict_target(["sku"])
      |> SelectoUpdato.on_conflict({:replace, [:name, :status]})
      |> SelectoUpdato.returning(:all)

    assert {:ok, %Item{id: 100, sku: "SKU-1"}} = SelectoUpdato.execute(op, FakeMSSQLRepo)

    assert_received {:repo_insert_opts, opts}
    assert opts[:returning] == true
    assert opts[:conflict_target] == [:sku]
    assert opts[:on_conflict] == {:replace, [:name, :status]}
  end

  test "mssql bulk upsert returns projected records" do
    op =
      SelectoUpdato.new(domain())
      |> SelectoUpdato.upsert_all([
        %{name: "A", status: "draft", sku: "SKU-1"},
        %{name: "B", status: "published", sku: "SKU-2"}
      ])
      |> SelectoUpdato.conflict_target(["sku"])
      |> SelectoUpdato.on_conflict({:replace, [:name, :status]})
      |> SelectoUpdato.returning([:id, :sku])

    assert {:ok, %{upserted: 2, records: [%{id: 1, sku: "SKU-1"}, %{id: 2, sku: "SKU-2"}]}} =
             SelectoUpdato.execute(op, FakeMSSQLRepo)

    assert_received {:repo_insert_all_opts, Item, _records, opts}
    assert opts[:returning] == [:id, :sku]
    assert opts[:conflict_target] == [:sku]
    assert opts[:on_conflict] == {:replace, [:name, :status]}
  end

  defp domain do
    %{
      source: Item,
      primary_key: "id",
      columns: %{
        "id" => %{type: :integer},
        "name" => %{type: :string},
        "status" => %{type: :string},
        "sku" => %{type: :string}
      },
      readonly: ["id"],
      required_on_insert: ["name"]
    }
  end
end
