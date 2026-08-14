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

defmodule Iri.Integrations.VNDB.Client do
  @moduledoc "Public VNDB Kana API client for store lookups and manual title searches."

  alias Iri.Integrations.{Error, HTTP}
  alias Iri.Library.Title

  @base_url "https://api.vndb.org/kana"
  @batch_size 100
  @game_fields Enum.join(
                 [
                   "id",
                   "title",
                   "alttitle",
                   "titles{title,latin,main}",
                   "released",
                   "description",
                   "rating",
                   "votecount",
                   "platforms",
                   "image{id,url,thumbnail,sexual,violence}",
                   "screenshots{id,url,thumbnail,sexual,violence}",
                   "developers{id,name}",
                   "tags{id,name,category,rating,spoiler}"
                 ],
                 ","
               )
  @release_fields "id,minage,has_ero,extlinks{name,id},vns{id}"

  def lookup_steam_games(app_ids, options \\ []) do
    lookup_games(:steam, app_ids, options)
  end

  def lookup_games(provider, external_ids, options \\ []) when provider in [:steam, :gog] do
    external_ids = external_ids |> Enum.map(&to_string/1) |> Enum.uniq()

    with {:ok, releases} <- lookup_releases(provider, external_ids, options),
         {:ok, games} <- games(release_game_ids(releases), options) do
      games_by_id = Map.new(games, &{&1["id"], &1})
      {:ok, group_by_external_id(releases, Atom.to_string(provider), games_by_id)}
    end
  end

  defp lookup_releases(provider, external_ids, options) do
    external_ids
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, found} ->
      case lookup_release_chunk(provider, chunk, options) do
        {:ok, releases} -> {:cont, {:ok, found ++ releases}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def search_games(query, options \\ []) when is_binary(query) do
    query = Title.for_provider_search(query)

    if query == "" do
      {:ok, []}
    else
      vn_request(
        %{
          filters: ["search", "=", query],
          fields: @game_fields,
          sort: "searchrank",
          results: Keyword.get(options, :results, 10)
        },
        options
      )
    end
  end

  def games(ids, options \\ []) do
    ids = ids |> Enum.map(&to_string/1) |> Enum.uniq()

    ids
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, found} ->
      case games_chunk(chunk, options) do
        {:ok, games} -> {:cont, {:ok, found ++ games}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp games_chunk([], _options), do: {:ok, []}

  defp games_chunk(ids, options) do
    filters =
      case Enum.map(ids, &["id", "=", &1]) do
        [filter] -> filter
        filters -> ["or" | filters]
      end

    vn_request(%{filters: filters, fields: @game_fields, results: length(ids)}, options)
  end

  defp lookup_release_chunk(_provider, [], _options), do: {:ok, []}

  defp lookup_release_chunk(provider, external_ids, options) do
    site = Atom.to_string(provider)

    filters =
      case Enum.map(external_ids, &["extlink", "=", [site, external_id(provider, &1)]]) do
        [filter] -> filter
        filters -> ["or" | filters]
      end

    request_options = [
      method: :post,
      url: Keyword.get(options, :base_url, @base_url) <> "/release",
      headers: [{"accept", "application/json"}, {"content-type", "application/json"}],
      json: %{filters: filters, fields: @release_fields, results: @batch_size}
    ]

    with {:ok, response} <- request(request_options, options),
         %{"results" => releases} when is_list(releases) <- response.body do
      {:ok, releases}
    else
      {:error, _reason} = error -> error
      _response -> {:error, invalid_response()}
    end
  end

  defp vn_request(body, options) do
    request_options = [
      method: :post,
      url: Keyword.get(options, :base_url, @base_url) <> "/vn",
      headers: [{"accept", "application/json"}, {"content-type", "application/json"}],
      json: body
    ]

    with {:ok, response} <- request(request_options, options),
         %{"results" => games} when is_list(games) <- response.body do
      {:ok, games}
    else
      {:error, _reason} = error -> error
      _response -> {:error, invalid_response()}
    end
  end

  defp release_game_ids(releases) do
    releases
    |> Enum.flat_map(&Map.get(&1, "vns", []))
    |> Enum.map(& &1["id"])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp group_by_external_id(releases, site, games_by_id) do
    Enum.reduce(releases, %{}, fn release, grouped ->
      external_ids =
        release
        |> Map.get("extlinks", [])
        |> Enum.filter(&(&1["name"] == site))
        |> Enum.map(&to_string(&1["id"]))

      games =
        release
        |> Map.get("vns", [])
        |> Enum.map(&Map.get(games_by_id, &1["id"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Map.put(&1, "_release", Map.take(release, ["id", "has_ero", "minage"])))

      Enum.reduce(external_ids, grouped, fn external_id, current ->
        Map.update(current, external_id, games, &(games ++ &1))
      end)
    end)
    |> Map.new(fn {app_id, games} -> {app_id, Enum.uniq_by(games, & &1["id"])} end)
  end

  defp external_id(:steam, value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp external_id(:gog, value), do: value

  defp request(options, client_options) do
    client_options
    |> Keyword.get(:request, &HTTP.request/2)
    |> then(& &1.(options, :vndb))
  end

  defp invalid_response do
    %Error{
      kind: :invalid_response,
      message: "VNDB returned an invalid response.",
      retryable: false,
      provider: :vndb
    }
  end
end
