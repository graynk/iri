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

defmodule Iri.Integrations.IGDB.Client do
  @moduledoc "Req adapter for Twitch application authentication and IGDB APICalypse queries."

  alias Iri.Integrations.Error
  alias Iri.Integrations.HTTP
  alias Iri.Integrations.IGDB.RateLimiter
  alias Iri.Library.Title

  @token_url "https://id.twitch.tv/oauth2/token"
  @base_url "https://api.igdb.com/v4"

  @game_fields Enum.join(
                 [
                   "id",
                   "name",
                   "slug",
                   "summary",
                   "first_release_date",
                   "total_rating",
                   "cover.image_id",
                   "genres.id",
                   "genres.name",
                   "genres.slug",
                   "themes.id",
                   "themes.name",
                   "themes.slug",
                   "keywords.id",
                   "keywords.name",
                   "keywords.slug",
                   "game_modes.id",
                   "game_modes.name",
                   "game_modes.slug",
                   "player_perspectives.id",
                   "player_perspectives.name",
                   "player_perspectives.slug",
                   "platforms.id",
                   "platforms.name",
                   "platforms.slug",
                   "involved_companies.company.id",
                   "involved_companies.company.name",
                   "involved_companies.company.slug",
                   "involved_companies.developer",
                   "involved_companies.publisher",
                   "screenshots.image_id",
                   "videos.name",
                   "videos.video_id"
                 ],
                 ","
               )

  def authenticate(client_id, client_secret, options \\ []) do
    request_options = [
      method: :post,
      url: Keyword.get(options, :token_url, @token_url),
      params: [
        client_id: client_id,
        client_secret: client_secret,
        grant_type: "client_credentials"
      ]
    ]

    with {:ok, response} <- request(request_options, options),
         %{"access_token" => token, "expires_in" => expires_in}
         when is_binary(token) and is_integer(expires_in) <- response.body do
      {:ok,
       %{
         "client_id" => client_id,
         "access_token" => token,
         "expires_at" => DateTime.add(DateTime.utc_now(:second), expires_in, :second)
       }}
    else
      {:error, _error} = error -> error
      _other -> {:error, invalid_response("Twitch returned an invalid application token")}
    end
  end

  def discover_external_source(credentials, source_name, options \\ []) do
    query("external_game_sources", "fields id,name; limit 500;", credentials, options)
    |> case do
      {:ok, sources} ->
        source = Enum.find(sources, &source_matches?(&1["name"], source_name))
        if source, do: {:ok, source["id"]}, else: {:error, :external_source_not_found}

      error ->
        error
    end
  end

  def external_games(credentials, source_id, uids, options \\ [])

  def external_games(_credentials, _source_id, [], _options), do: {:ok, []}

  def external_games(credentials, source_id, uids, options) do
    values = uids |> Enum.map(&to_string/1) |> Enum.map_join(",", &Jason.encode!/1)

    body =
      "fields uid,game,name; where external_game_source = #{source_id} & uid = (#{values}); limit 500;"

    query("external_games", body, credentials, options)
  end

  def games(credentials, ids, options \\ [])

  def games(_credentials, [], _options), do: {:ok, []}

  def games(credentials, ids, options) do
    values = ids |> Enum.uniq() |> Enum.map_join(",", &to_string/1)

    with {:ok, games} <-
           query(
             "games",
             "fields #{@game_fields}; where id = (#{values}); limit 500;",
             credentials,
             options
           ),
         {:ok, times} <- game_times_to_beat(credentials, ids, options) do
      times_by_game = Map.new(times, &{&1["game_id"], &1})

      {:ok,
       Enum.map(games, fn game ->
         Map.put(game, "time_to_beat", Map.get(times_by_game, game["id"]))
       end)}
    end
  end

  defp game_times_to_beat(credentials, ids, options) do
    values = ids |> Enum.uniq() |> Enum.map_join(",", &to_string/1)

    query(
      "game_time_to_beats",
      "fields game_id,hastily,normally; where game_id = (#{values}); limit 500;",
      credentials,
      options
    )
  end

  def search_games(credentials, search, options \\ []) do
    case Title.for_provider_search(search) do
      "" ->
        {:ok, []}

      search ->
        escaped = Jason.encode!(search)

        body =
          "search #{escaped}; fields id,name,summary,first_release_date,game_type.type,platforms.id,platforms.name,involved_companies.company.name,involved_companies.developer,involved_companies.publisher; limit 20;"

        query("games", body, credentials, options)
    end
  end

  def query(endpoint, body, credentials, options \\ []) do
    with {:ok, client_id, token} <- auth_headers(credentials),
         :ok <- acquire(options),
         {:ok, response} <-
           request(
             [
               method: :post,
               url: Keyword.get(options, :base_url, @base_url) <> "/" <> endpoint,
               headers: [
                 {"client-id", client_id},
                 {"authorization", "Bearer #{token}"},
                 {"accept", "application/json"},
                 {"content-type", "text/plain"}
               ],
               body: body
             ],
             options
           ),
         response_body when is_list(response_body) <- response.body do
      {:ok, response_body}
    else
      {:error, _error} = error -> error
      _other -> {:error, invalid_response("IGDB returned an invalid response")}
    end
  end

  defp auth_headers(%{"client_id" => client_id, "access_token" => token})
       when is_binary(client_id) and is_binary(token),
       do: {:ok, client_id, token}

  defp auth_headers(_credentials), do: {:error, :not_configured}

  defp acquire(options) do
    options |> Keyword.get(:rate_limit, &RateLimiter.acquire/0) |> then(& &1.())
  end

  defp request(request_options, options) do
    request_fun = Keyword.get(options, :request, &HTTP.request/2)
    request_fun.(request_options, :igdb)
  end

  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp source_matches?(actual, requested) do
    actual = normalize(actual)
    requested = normalize(requested)

    actual == requested or actual in source_aliases(requested)
  end

  defp source_aliases("gog"), do: ["gog.com"]
  defp source_aliases("epic game store"), do: ["epic games store"]
  defp source_aliases("playstation store"), do: ["playstation store us"]
  defp source_aliases(_requested), do: []

  defp invalid_response(message) do
    %Error{
      kind: :invalid_response,
      message: message,
      retryable: false,
      provider: :igdb
    }
  end
end
