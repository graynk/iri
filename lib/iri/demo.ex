# This file is part of IRI.
#
# Copyright (C) 2026 Nikita Karpukhin
#
# IRI is free software: you can redistribute it and/or modify it under the
# terms of the GNU Affero General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version.
#
# IRI is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for
# more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with IRI. If not, see <https://www.gnu.org/licenses/>.

defmodule Iri.Demo do
  @moduledoc "Validates a demo snapshot and holds its write-free viewer identity."

  use GenServer

  alias Iri.Accounts.{Scope, User}
  alias Iri.Repo

  @username "demo"

  @doc "Starts the demo identity after validating the snapshot."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the immutable viewer scope loaded from the configured snapshot user."
  def scope(server \\ __MODULE__), do: GenServer.call(server, :scope)

  @impl true
  def init(_opts) do
    with :ok <- validate_migrations(),
         {:ok, scope} <- load_scope() do
      {:ok, scope}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:scope, _from, scope), do: {:reply, scope, scope}

  defp validate_migrations do
    expected =
      Iri.Repo
      |> Ecto.Migrator.migrations_path()
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.map(&migration_version!/1)
      |> Enum.sort()

    actual =
      case Ecto.Adapters.SQL.query(Repo, "SELECT version FROM schema_migrations ORDER BY version") do
        {:ok, %{rows: rows}} -> Enum.map(rows, fn [version] -> version end)
        {:error, error} -> {:error, error}
      end

    case actual do
      {:error, error} ->
        {:error, "cannot read demo snapshot migrations: #{Exception.message(error)}"}

      versions ->
        case expected -- versions do
          [] ->
            :ok

          missing ->
            {:error,
             "demo snapshot schema is incompatible; missing migrations #{inspect(missing)}"}
        end
    end
  end

  defp load_scope do
    case Repo.get_by(User, username: @username) do
      %User{} = user ->
        viewer = %{user | role: :viewer, hashed_password: nil, password: nil}
        {:ok, %Scope{user: viewer, role: :viewer}}

      nil ->
        {:error, "required demo user #{@username |> inspect()} does not exist in the snapshot"}
    end
  end

  defp migration_version!(path) do
    path
    |> Path.basename()
    |> String.split("_", parts: 2)
    |> hd()
    |> String.to_integer()
  end
end
