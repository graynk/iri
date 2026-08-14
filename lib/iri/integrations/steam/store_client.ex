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

defmodule Iri.Integrations.Steam.StoreClient do
  @moduledoc "Fetches public Steam Store and Deck compatibility metadata."

  alias Iri.Integrations.{Error, HTTP}

  @store_url "https://store.steampowered.com/api/appdetails"
  @deck_url "https://store.steampowered.com/saleaction/ajaxgetdeckappcompatibilityreport"

  def fetch_app_details(app_id, options \\ []) when is_binary(app_id) do
    with {:ok, data} <- fetch_store_data(app_id, options),
         title when is_binary(title) and title != "" <- data["name"] do
      {:ok,
       %{
         app_id: app_id,
         title: title,
         catalog_kind: catalog_kind(data),
         source_url: "https://store.steampowered.com/app/#{app_id}",
         metadata_snapshot:
           Map.take(data, ["steam_appid", "name", "type", "is_free", "required_age"])
       }}
    else
      nil -> {:error, invalid_response("Steam Store returned app metadata without a title")}
      "" -> {:error, invalid_response("Steam Store returned app metadata without a title")}
      error -> error
    end
  end

  def fetch_metadata(app_id, options \\ []) when is_binary(app_id) do
    case fetch_store_metadata(app_id, options) do
      {:ok, store} ->
        {:ok, add_deck_compatibility(store, app_id, options)}

      {:error, :store_metadata_unavailable} ->
        {:ok, add_deck_compatibility(%{}, app_id, options)}

      {:error, _reason} = error ->
        error
    end
  end

  def fetch_store_metadata(app_id, options \\ []) when is_binary(app_id) do
    fetch_store(app_id, options)
  end

  def fetch_deck_compatibility(app_id, options \\ []) when is_binary(app_id) do
    request_options = [
      method: :get,
      url: Keyword.get(options, :deck_url, @deck_url),
      params: [nAppID: app_id, l: "english"]
    ]

    case request(request_options, :steam, options) do
      {:ok, %{body: %{"success" => 1, "results" => results}}} ->
        {:ok, deck_category(container_value(results, "resolved_category", :resolved_category))}

      {:ok, _response} ->
        {:error, invalid_response("Steam Deck returned invalid compatibility metadata")}

      {:error, _reason} = error ->
        error
    end
  end

  def catalog_kind_from_title(title) when is_binary(title) do
    cond do
      Regex.match?(~r/\b(?:playtest|public test|test server|technical test|beta)\b/i, title) ->
        "playtest"

      Regex.match?(~r/\bdemo\b/i, title) ->
        "demo"

      Regex.match?(~r/\bdedicated server\b/i, title) ->
        "tool"

      Regex.match?(~r/\b(soundtracks?|art ?books?|toolkit|redkit|sdk)\b/i, title) ->
        "software"

      true ->
        nil
    end
  end

  def catalog_kind_from_title(_title), do: nil

  defp fetch_store(app_id, options) do
    with {:ok, data} <- fetch_store_data(app_id, options) do
      platforms = map_value(data["platforms"])

      {:ok,
       %{
         catalog_kind: catalog_kind(data),
         nsfw: nsfw?(data),
         controller_support: controller_support(data["controller_support"]),
         available_windows: platforms["windows"] == true,
         available_mac: platforms["mac"] == true,
         available_linux: platforms["linux"] == true,
         vr_support: vr_support(data["categories"])
       }}
    end
  end

  defp fetch_store_data(app_id, options) do
    request_options = [
      method: :get,
      url: Keyword.get(options, :store_url, @store_url),
      params: [appids: app_id, cc: "us", l: "english"]
    ]

    with {:ok, response} <- request(request_options, :steam, options),
         %{"success" => true, "data" => data} when is_map(data) <- response.body[app_id] do
      {:ok, data}
    else
      {:error, _error} = error -> error
      %{"success" => false} -> {:error, :store_metadata_unavailable}
      _response -> {:error, invalid_response("Steam Store returned invalid app metadata")}
    end
  end

  defp add_deck_compatibility(metadata, app_id, options),
    do: Map.put(metadata, :deck_compatibility, fetch_deck(app_id, options))

  defp fetch_deck(app_id, options) do
    case fetch_deck_compatibility(app_id, options) do
      {:ok, compatibility} -> compatibility
      {:error, _reason} -> "unknown"
    end
  end

  defp request(request_options, provider, options) do
    Keyword.get(options, :request, &HTTP.request/2).(request_options, provider)
  end

  defp controller_support(value) when value in ["full", "partial"], do: value
  defp controller_support(_value), do: "none"

  defp catalog_kind(data) do
    type = data["type"] |> to_string() |> String.downcase()
    name = data["name"] |> to_string() |> String.downcase()

    genres =
      data
      |> Map.get("genres", [])
      |> Enum.map(&String.downcase(to_string(&1["description"] || "")))

    cond do
      kind = catalog_kind_from_title(name) -> kind
      type in ["dlc", "demo", "video", "series", "episode", "music", "advertising"] -> type
      type in ["tool", "application"] -> "software"
      type == "game" and software_genre?(genres) -> "software"
      type in ["game", "mod"] -> "game"
      type == "" -> "unknown"
      true -> type
    end
  end

  defp software_genre?(genres) do
    Enum.any?(genres, fn genre ->
      genre in [
        "utilities",
        "audio production",
        "video production",
        "web publishing",
        "animation & modeling",
        "design & illustration",
        "software training",
        "game development",
        "photo editing"
      ]
    end)
  end

  defp nsfw?(data) do
    (Map.get(data, "genres", []) ++ Map.get(data, "categories", []))
    |> Enum.map(&(&1["description"] |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.any?(&(&1 in ["adult only", "hentai", "erotic", "sexually explicit"]))
  end

  defp vr_support(categories) when is_list(categories) do
    descriptions =
      categories
      |> Enum.map(&String.downcase(to_string(&1["description"] || "")))

    cond do
      Enum.any?(descriptions, &String.contains?(&1, "vr only")) -> "required"
      Enum.any?(descriptions, &String.contains?(&1, "vr support")) -> "supported"
      true -> "none"
    end
  end

  defp vr_support(_categories), do: "none"

  defp deck_category(3), do: "verified"
  defp deck_category(2), do: "playable"
  defp deck_category(1), do: "unsupported"
  defp deck_category(_category), do: "unknown"

  defp map_value(value) when is_map(value), do: value
  defp map_value(_value), do: %{}

  defp container_value(container, string_key, atom_key) when is_map(container),
    do: Map.get(container, string_key) || Map.get(container, atom_key)

  defp container_value(container, _string_key, atom_key) when is_list(container) do
    if Keyword.keyword?(container), do: Keyword.get(container, atom_key)
  end

  defp container_value(_container, _string_key, _atom_key), do: nil

  defp invalid_response(message) do
    %Error{
      kind: :invalid_response,
      message: message,
      retryable: true,
      provider: :steam
    }
  end
end
