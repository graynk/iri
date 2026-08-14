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

defmodule Iri.Integrations.Xbox.Client do
  @moduledoc "OpenXBL profile and partial title-history client."

  @behaviour Iri.Integrations.Provider

  require Logger

  alias Iri.Integrations.{Error, HTTP}
  alias Iri.Integrations.Xbox.RateLimiter
  alias Iri.Security.Redactor

  @base_url "https://xbl.io/api/v2"

  def resolve_profile(gamertag, api_key, options \\ []) do
    query = String.trim(gamertag)
    # Modern gamertags carry a #suffix discriminator that the search endpoint
    # does not accept; search on the base name and match the suffix locally.
    base = query |> String.split("#") |> hd() |> String.trim()

    with {:ok, response} <- get("/search/#{URI.encode(base)}", api_key, options),
         {:ok, body} <- response_content(response.body),
         {:ok, profile} <- parse_profile(body, query) do
      {:ok, profile}
    end
  end

  @impl true
  def fetch_library(account, api_key, options \\ []) do
    with {:ok, response} <-
           get(
             "/player/titleHistory/#{URI.encode(account.external_user_id)}",
             api_key,
             options
           ),
         {:ok, body} <- response_content(response.body),
         {:ok, titles} <- parse_titles(body) do
      {:ok, titles}
    end
  end

  defp get(path, api_key, options) do
    with :ok <- Keyword.get(options, :rate_limit, &RateLimiter.acquire/0).() do
      request = Keyword.get(options, :request, &HTTP.request/2)

      headers = [{"x-authorization", api_key}, {"accept", "application/json"}]

      result =
        request.(
          [
            method: :get,
            url: Keyword.get(options, :base_url, @base_url) <> path,
            headers: headers,
            receive_timeout: 30_000,
            retry: false
          ],
          :xbox
        )

      case result do
        {:ok, response} ->
          observe(options, response.headers, response.status)
          {:ok, response}

        {:error, %Error{status: status} = error} ->
          observe(options, [], status)
          {:error, error}

        error ->
          error
      end
    else
      {:error, {:rate_limited, until}} ->
        {:error,
         %Error{
           kind: :rate_limited,
           message: "OpenXBL request budget is exhausted until #{DateTime.to_iso8601(until)}",
           retryable: true,
           status: 429,
           provider: :xbox
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp observe(options, headers, status) do
    Keyword.get(options, :observe, &RateLimiter.observe/2).(headers, status)
  end

  defp parse_profile(body, query) do
    candidates =
      (body["people"] || body["profileUsers"] || body["results"] || List.wrap(body))
      |> List.wrap()
      |> Enum.flat_map(&normalize_profile/1)

    case candidates do
      [] ->
        {:error, invalid("OpenXBL did not find that gamertag")}

      candidates ->
        # Several accounts can share a base name; only the #suffix separates
        # them. Prefer the exact tag over whichever result happens to be first.
        {:ok, Enum.find(candidates, &tag_matches?(&1, query)) || List.first(candidates)}
    end
  end

  defp normalize_profile(profile) when is_map(profile) do
    settings =
      profile["settings"]
      |> List.wrap()
      |> Map.new(fn item -> {item["id"], item["value"]} end)

    xuid = profile["xuid"] || profile["id"]
    gamertag = profile["gamertag"] || settings["Gamertag"]
    modern = settings["ModernGamertag"] || gamertag
    suffix = settings["ModernGamertagSuffix"]

    unique =
      settings["UniqueModernGamertag"] ||
        if(suffix in [nil, ""], do: modern, else: "#{modern}##{suffix}")

    if xuid && gamertag do
      [
        %{
          xuid: to_string(xuid),
          gamertag: gamertag,
          unique_gamertag: unique
        }
      ]
    else
      []
    end
  end

  defp normalize_profile(_profile), do: []

  defp tag_matches?(_profile, nil), do: false

  defp tag_matches?(profile, query) do
    down = String.downcase(query)

    String.downcase(profile.unique_gamertag || "") == down or
      String.downcase(profile.gamertag) == down
  end

  defp parse_titles(body) do
    titles = body["titles"] || get_in(body, ["titleHistory", "titles"]) || body["items"]

    if is_list(titles) do
      {:ok, Enum.flat_map(titles, &normalize_title/1)}
    else
      {:error, invalid("OpenXBL returned an invalid title history")}
    end
  end

  defp response_content(%{"code" => code, "content" => content}) when code in 200..299,
    do: {:ok, content}

  defp response_content(%{"code" => code} = body) when is_integer(code) do
    detail = body["message"] || body["error"] || "OpenXBL returned an error"
    Logger.warning("OpenXBL response envelope reported code=#{code}")

    {:error,
     %Error{
       kind: :unexpected_response,
       message:
         "OpenXBL returned code #{code}: #{detail |> to_string() |> Redactor.redact() |> String.slice(0, 200)}",
       retryable: code == 429 or code >= 500,
       status: code,
       provider: :xbox
     }}
  end

  defp response_content(body), do: {:ok, body}

  defp normalize_title(title) do
    id = title["titleId"] || title["id"] || title["pfn"]
    name = title["name"] || title["titleName"]

    if (id && is_binary(name)) and String.trim(name) != "" and not non_game_title?(title, name) do
      [
        %{
          external_id: to_string(id),
          title: name,
          relationship: :played,
          playtime_minutes: minutes(title),
          metadata: %{"openxbl" => title}
        }
      ]
    else
      []
    end
  end

  @doc "Whether an already stored game source would be filtered by the current import rules."
  def non_game_source?(%{source_title: title, metadata_snapshot: snapshot}) do
    non_game_title?(get_in(snapshot, ["openxbl"]) || %{}, title)
  end

  # Title history mixes full games with apps, demos, trials, and every desktop
  # game the Windows Game Bar ever logged. The type field separates apps, the
  # Win32-only device marks Game Bar captures of Steam/GOG installs (not Xbox
  # ownership), and demos betray themselves through trailing name markers,
  # which the marketplace localizes ("демоверсия").
  defp non_game_title?(title, name) do
    type = title["type"] || title["titleType"]

    (is_binary(type) and String.downcase(type) != "game") or
      game_bar_capture?(title["devices"]) or
      Regex.match?(
        ~r/[\s(\[–—:-](?:game\s+)?(?:demo(?:version)?|trial|testversion|testfassung|probeversion|демо(?:версия)?)[)\]]?$/iu,
        String.trim(name)
      )
  end

  defp game_bar_capture?(devices) when is_list(devices) and devices != [],
    do: Enum.all?(devices, &(&1 == "Win32"))

  defp game_bar_capture?(_devices), do: false

  defp minutes(title) do
    value = title["minutesPlayed"] || get_in(title, ["stats", "minutesPlayed"])
    if is_integer(value) and value >= 0, do: value
  end

  defp invalid(message),
    do: %Error{kind: :invalid_response, message: message, retryable: false, provider: :xbox}
end
