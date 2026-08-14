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

defmodule Iri.Integrations.GOG.Client do
  @moduledoc "Credential-free Req client for GOG public profile ownership and playtime."

  @behaviour Iri.Integrations.Provider

  alias Iri.Integrations.Error
  alias Iri.Integrations.GOG.RateLimiter
  alias Iri.Integrations.HTTP

  @base_url "https://www.gog.com"
  @max_pages 100
  @max_games 10_000

  def validate_profile(input, options \\ []) do
    with {:ok, username} <- normalize_username(input),
         {:ok, page} <- fetch_page(username, 1, options) do
      {:ok,
       %{
         username: username,
         display_name: username,
         total: page.total
       }}
    end
  end

  @impl true
  def fetch_library(account, _payload, options) do
    with {:ok, username} <- normalize_username(account.external_user_id),
         {:ok, first} <- fetch_page(username, 1, options),
         :ok <- validate_page_count(first.pages),
         {:ok, items} <- fetch_remaining(username, first, options) do
      games =
        items
        |> Enum.reject(&non_game_product?/1)
        |> Enum.uniq_by(&to_string(&1["id"]))

      {:ok, games}
    end
  end

  def normalize_username(input) when is_binary(input) do
    value = String.trim(input)

    username =
      case URI.parse(value) do
        %URI{scheme: scheme, host: host, path: path}
        when scheme in ["http", "https"] and host in ["gog.com", "www.gog.com"] ->
          path
          |> to_string()
          |> String.split("/", trim: true)
          |> case do
            ["u", username | _rest] -> username
            _parts -> nil
          end

        %URI{scheme: nil, host: nil} ->
          value

        _uri ->
          nil
      end

    if is_binary(username) and Regex.match?(~r/^[\p{L}\p{N}_.-]{1,100}$/u, username) do
      {:ok, username}
    else
      {:error, :invalid_gog_profile}
    end
  end

  def normalize_username(_input), do: {:error, :invalid_gog_profile}

  defp fetch_remaining(username, first, options) do
    if first.pages <= 1 do
      {:ok, first.items}
    else
      Enum.reduce_while(2..first.pages, {:ok, first.items}, fn page_number, {:ok, items} ->
        case fetch_page(username, page_number, options) do
          {:ok, page} when page.pages == first.pages and page.page == page_number ->
            combined = items ++ page.items

            if length(combined) <= @max_games do
              {:cont, {:ok, combined}}
            else
              {:halt, {:error, invalid_response("GOG profile contains too many products")}}
            end

          {:ok, _page} ->
            {:halt, {:error, invalid_response("GOG pagination changed during import")}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
    end
  end

  defp fetch_page(username, page, options) do
    with :ok <- acquire(options),
         request_fun <- Keyword.get(options, :request, &HTTP.request/2),
         {:ok, response} <-
           request_fun.(
             [
               method: :get,
               url:
                 Keyword.get(options, :base_url, @base_url) <>
                   "/u/#{URI.encode(username)}/games/stats",
               params: [sort: "total_playtime", order: "desc", page: page],
               headers: [{"accept", "application/hal+json, application/json"}],
               redirect: false,
               receive_timeout: 30_000
             ],
             :gog
           ),
         {:ok, parsed} <- parse_page(response.body) do
      {:ok, parsed}
    end
  end

  defp parse_page(%{
         "page" => page,
         "pages" => pages,
         "total" => total,
         "_embedded" => %{"items" => items}
       })
       when is_integer(page) and is_integer(pages) and is_integer(total) and is_list(items) and
              page >= 1 and pages >= 0 and total >= 0 do
    with true <- Enum.all?(items, &valid_item?/1) do
      {:ok, %{page: page, pages: pages, total: total, items: Enum.map(items, &normalize_item/1)}}
    else
      false -> {:error, invalid_response("GOG returned an invalid game entry")}
    end
  end

  defp parse_page(_body), do: {:error, invalid_response("GOG returned an invalid profile page")}

  defp valid_item?(%{"game" => %{"id" => id, "title" => title}}) do
    (is_integer(id) or is_binary(id)) and is_binary(title) and String.trim(title) != ""
  end

  defp valid_item?(_item), do: false

  defp normalize_item(%{"game" => game} = item) do
    %{
      "id" => to_string(game["id"]),
      "title" => game["title"],
      "url" => game["url"],
      "image" => game["image"],
      "achievement_support" => game["achievementSupport"],
      "stats" => normalize_stats(item["stats"])
    }
  end

  defp normalize_stats(stats) when is_map(stats) do
    stats
    |> Enum.find_value(%{}, fn {user_id, value} ->
      if is_map(value), do: Map.put(value, "user_id", to_string(user_id))
    end)
  end

  defp normalize_stats(_stats), do: %{}

  # GOG exposes a handful of downloadable extras through the public game-stats
  # feed. They have game-shaped records and URLs, so filter the stable title
  # conventions defensively before they reach matching or the library.
  defp non_game_product?(%{"title" => title}) when is_binary(title) do
    Regex.match?(~r/^GOG Product \d+$/i, title) or
      Regex.match?(~r/\bGoodies Collection\b/i, title) or
      Regex.match?(~r/\bREDkit\b/i, title) or
      Regex.match?(
        ~r/(?:^|[-:])\s*(?:digital )?(?:art ?book|soundtrack|wallpapers?|extras)\s*$/i,
        title
      )
  end

  defp non_game_product?(_item), do: false

  defp validate_page_count(pages) when is_integer(pages) and pages <= @max_pages, do: :ok
  defp validate_page_count(_pages), do: {:error, invalid_response("GOG returned too many pages")}

  defp acquire(options) do
    options |> Keyword.get(:rate_limit, &RateLimiter.acquire/0) |> then(& &1.())
  end

  defp invalid_response(message) do
    %Error{kind: :invalid_response, message: message, retryable: false, provider: :gog}
  end
end
