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

defmodule Iri.Integrations.Epic.LegendaryParser do
  @moduledoc "Strict parser for Legendary's `list --json` export."

  @max_bytes 20_000_000
  @max_entries 10_000

  def parse(binary) when is_binary(binary) and byte_size(binary) <= @max_bytes do
    with {:ok, payload} <- Jason.decode(binary),
         true <- is_list(payload),
         true <- length(payload) <= @max_entries do
      entries = payload |> Enum.flat_map(&normalize/1) |> Enum.uniq_by(& &1.external_id)
      {:ok, entries}
    else
      {:error, _reason} -> {:error, :invalid_json}
      false -> {:error, :invalid_legendary_export}
    end
  end

  def parse(_binary), do: {:error, :file_too_large}

  defp normalize(%{"metadata" => metadata} = item) when is_map(metadata) do
    title = clean(item["title"] || metadata["title"])
    id = clean(metadata["id"] || metadata["catalogItemId"] || item["app_name"])
    categories = List.wrap(metadata["categories"])

    dlc? =
      item["is_dlc"] == true or metadata["mainGameItem"] != nil or category?(categories, "addons")

    if (title && id && not dlc?) and game_category?(categories) do
      [
        %{
          external_id: id,
          title: title,
          source_url: epic_url(metadata),
          relationship: :owned,
          metadata: %{
            "legendary" => %{
              "catalog_item_id" => id,
              "namespace" => metadata["namespace"],
              "app_name" => item["app_name"],
              "image" => image(metadata),
              "developer" => metadata["developer"]
            }
          }
        }
      ]
    else
      []
    end
  end

  defp normalize(_item), do: []

  defp clean(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp clean(_value), do: nil
  defp category?(categories, value), do: Enum.any?(categories, &(&1["path"] == value))

  defp game_category?([]), do: true

  defp game_category?(categories),
    do: category?(categories, "games") || category?(categories, "applications")

  defp image(metadata) do
    metadata["keyImages"]
    |> List.wrap()
    |> Enum.find_value(fn image ->
      if image["type"] in ["DieselGameBoxTall", "OfferImageTall", "Thumbnail"], do: image["url"]
    end)
  end

  defp epic_url(metadata) do
    slug = metadata["productSlug"] || metadata["urlSlug"]
    if clean(slug), do: "https://store.epicgames.com/p/#{slug}"
  end
end
