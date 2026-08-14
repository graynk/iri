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

defmodule Iri.Integrations.IGDB.TokenManager do
  @moduledoc "Keeps the short-lived IGDB application token in memory and secrets in runtime config."

  use GenServer

  alias Iri.Integrations.IGDB.Client

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  def configured? do
    match?({:ok, _client_id, _client_secret}, configured_client())
  end

  def credentials(
        client \\ Application.get_env(:iri, :igdb_client, Client),
        options \\ []
      ) do
    GenServer.call(__MODULE__, {:credentials, client, options}, :infinity)
  end

  @doc false
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(_options), do: {:ok, %{fingerprint: nil, payload: nil}}

  @impl true
  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{fingerprint: nil, payload: nil}}
  end

  def handle_call({:credentials, client, options}, _from, state) do
    case configured_client() do
      {:ok, client_id, client_secret} ->
        fingerprint = :crypto.hash(:sha256, client_id <> <<0>> <> client_secret)

        if state.fingerprint == fingerprint and token_fresh?(state.payload) do
          {:reply, {:ok, state.payload}, state}
        else
          refresh(client, client_id, client_secret, fingerprint, options, state)
        end

      {:error, :not_configured} = error ->
        {:reply, error, %{fingerprint: nil, payload: nil}}
    end
  end

  defp refresh(client, client_id, client_secret, fingerprint, options, state) do
    with {:ok, payload} <- client.authenticate(client_id, client_secret, options),
         {:ok, steam_source_id} <-
           client.discover_external_source(payload, "Steam", options),
         {:ok, gog_source_id} <- client.discover_external_source(payload, "GOG", options) do
      payload =
        payload
        |> Map.put("steam_source_id", steam_source_id)
        |> Map.put("gog_source_id", gog_source_id)
        |> maybe_source(client, options, "Epic Game Store", "epic_source_id")
        |> maybe_source(client, options, "PlayStation Store", "psn_source_id")
        |> maybe_source(client, options, "Xbox Marketplace", "xbox_source_id")

      {:reply, {:ok, payload}, %{fingerprint: fingerprint, payload: payload}}
    else
      error -> {:reply, error, state}
    end
  end

  defp maybe_source(payload, client, options, name, key) do
    case client.discover_external_source(payload, name, options) do
      {:ok, id} -> Map.put(payload, key, id)
      _error -> payload
    end
  rescue
    FunctionClauseError -> payload
  end

  defp configured_client do
    config = Application.get_env(:iri, :igdb_credentials, [])
    client_id = config[:client_id]
    client_secret = config[:client_secret]

    if present?(client_id) and present?(client_secret) do
      {:ok, client_id, client_secret}
    else
      {:error, :not_configured}
    end
  end

  defp token_fresh?(%{"expires_at" => %DateTime{} = expires_at}) do
    DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(:second), 300, :second)) == :gt
  end

  defp token_fresh?(_payload), do: false
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
