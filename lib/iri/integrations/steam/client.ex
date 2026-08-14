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

defmodule Iri.Integrations.Steam.Client do
  @moduledoc "Steam Web API adapter for public-profile ownership ingestion."

  @behaviour Iri.Integrations.Provider

  alias Iri.Integrations.Error
  alias Iri.Integrations.HTTP
  alias Iri.Integrations.ProviderAccount
  alias Iri.Integrations.Steam.ProfileParser

  @base_url "https://api.steampowered.com"

  @impl true
  def fetch_library(%ProviderAccount{} = account, payload, options \\ []) do
    with {:ok, api_key} <- api_key(payload) do
      get_owned_games(account.external_user_id, api_key, options)
    end
  end

  def validate_setup(profile_input, api_key, options \\ []) do
    with {:ok, parsed} <- ProfileParser.parse(profile_input),
         {:ok, steamid} <- resolve_parsed_profile(parsed, api_key, options),
         {:ok, profile} <- get_player_summary(steamid, api_key, options),
         {:ok, games} <- get_owned_games(steamid, api_key, options),
         :ok <- ensure_visible_library(games) do
      {:ok,
       %{
         steamid: steamid,
         display_name: profile["personaname"],
         game_count: length(games)
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, input_error(reason)}
      error -> error
    end
  end

  def resolve_profile(profile_input, api_key, options \\ []) do
    with {:ok, parsed} <- ProfileParser.parse(profile_input),
         {:ok, steamid} <- resolve_parsed_profile(parsed, api_key, options) do
      {:ok, steamid}
    else
      {:error, reason} when is_atom(reason) -> {:error, input_error(reason)}
      error -> error
    end
  end

  def get_player_summary(steamid, api_key, options \\ []) do
    request_options = [
      method: :get,
      url: endpoint(options, "/ISteamUser/GetPlayerSummaries/v2/"),
      params: [key: api_key, steamids: steamid, format: "json"]
    ]

    with {:ok, response} <- request(request_options, options),
         %{"response" => %{"players" => [profile | _]}} <- response.body do
      {:ok, profile}
    else
      {:ok, _response} -> {:error, invalid_response("Steam profile was not found")}
      {:error, _error} = error -> error
      _other -> {:error, invalid_response("Steam returned an invalid profile response")}
    end
  end

  def get_owned_games(steamid, api_key, options \\ []) do
    request_options = [
      method: :get,
      url: endpoint(options, "/IPlayerService/GetOwnedGames/v1/"),
      params: [
        key: api_key,
        steamid: steamid,
        include_appinfo: true,
        include_played_free_games: true,
        skip_unvetted_apps: false,
        format: "json"
      ]
    ]

    with {:ok, response} <- request(request_options, options),
         %{"response" => response_body} when is_map(response_body) <- response.body,
         games when is_list(games) <- Map.get(response_body, "games", []) do
      {:ok, games}
    else
      {:error, _error} = error -> error
      _other -> {:error, invalid_response("Steam returned an invalid owned-games response")}
    end
  end

  defp resolve_parsed_profile({:steamid, steamid}, _api_key, _options), do: {:ok, steamid}

  defp resolve_parsed_profile({:vanity, vanity}, api_key, options) do
    request_options = [
      method: :get,
      url: endpoint(options, "/ISteamUser/ResolveVanityURL/v1/"),
      params: [key: api_key, vanityurl: vanity, url_type: 1, format: "json"]
    ]

    with {:ok, response} <- request(request_options, options),
         %{"response" => %{"success" => 1, "steamid" => steamid}} <- response.body do
      {:ok, steamid}
    else
      {:ok, _response} -> {:error, :vanity_not_found}
      {:error, _error} = error -> error
      _other -> {:error, invalid_response("Steam returned an invalid vanity response")}
    end
  end

  defp api_key(%{"api_key" => api_key}) when is_binary(api_key) and byte_size(api_key) > 0,
    do: {:ok, api_key}

  defp api_key(%{"credential" => api_key}) when is_binary(api_key) and byte_size(api_key) > 0,
    do: {:ok, api_key}

  defp api_key(_payload), do: {:error, input_error(:missing_api_key)}

  defp ensure_visible_library([]), do: {:error, :library_not_visible}
  defp ensure_visible_library(_games), do: :ok

  defp request(request_options, options) do
    request_fun = Keyword.get(options, :request, &HTTP.request/2)
    request_fun.(request_options, :steam)
  end

  defp endpoint(options, path), do: Keyword.get(options, :base_url, @base_url) <> path

  defp input_error(:library_not_visible) do
    %Error{
      kind: :library_not_visible,
      message:
        "Steam returned no games. Make both Profile and Game Details public, then try again.",
      retryable: false,
      provider: :steam
    }
  end

  defp input_error(:vanity_not_found) do
    %Error{
      kind: :invalid_profile,
      message: "Steam could not resolve that vanity profile.",
      retryable: false,
      provider: :steam
    }
  end

  defp input_error(:missing_api_key) do
    %Error{
      kind: :authentication,
      message: "A Steam Web API key is required.",
      retryable: false,
      provider: :steam
    }
  end

  defp input_error(_reason) do
    %Error{
      kind: :invalid_profile,
      message: "Enter a SteamID64, vanity name, or Steam Community profile URL.",
      retryable: false,
      provider: :steam
    }
  end

  defp invalid_response(message) do
    %Error{
      kind: :invalid_response,
      message: message,
      retryable: false,
      provider: :steam
    }
  end
end
