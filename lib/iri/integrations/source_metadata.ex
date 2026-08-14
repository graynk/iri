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

defmodule Iri.Integrations.SourceMetadata do
  @moduledoc "Extracts bounded matching facts from provider-specific source metadata."

  alias Iri.Library.GameSource

  @generic_platform_keys ~w(platform platforms)

  def facts(%GameSource{metadata_snapshot: metadata}) when is_map(metadata) do
    developers =
      [
        metadata["developer"],
        metadata["developers"],
        get_in(metadata, ["legendary", "developer"])
      ]
      |> text_values()

    publishers = [metadata["publisher"], metadata["publishers"]] |> text_values()
    companies = text_values([metadata["companies"], developers, publishers])

    platforms =
      metadata
      |> values_for(@generic_platform_keys)
      |> Kernel.++([
        get_in(metadata, ["psn", "platform"]),
        get_in(metadata, ["psn", "platformName"]),
        get_in(metadata, ["psn", "platform_name"])
      ])
      |> text_values()

    %{}
    |> put_nonempty("developers", developers)
    |> put_nonempty("publishers", publishers)
    |> put_nonempty("companies", companies)
    |> put_nonempty("platforms", platforms)
    |> put_value("release_year", release_year(metadata))
    |> put_text("type", metadata["type"])
    |> put_text("app_type", metadata["app_type"])
    |> put_text("description", metadata["description"])
    |> put_text("short_description", metadata["short_description"])
  end

  def facts(%GameSource{}), do: %{}

  defp values_for(metadata, keys), do: Enum.map(keys, &Map.get(metadata, &1))

  defp text_values(values) do
    values
    |> List.flatten()
    |> Enum.flat_map(fn
      value when is_binary(value) -> String.split(value, ~r/[,;|]/u)
      %{"name" => value} when is_binary(value) -> [value]
      _value -> []
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp release_year(metadata) do
    Enum.find_value(~w(release_year release_date released), fn key ->
      metadata |> Map.get(key) |> parse_year()
    end)
  end

  defp parse_year(year) when is_integer(year) and year in 1970..3000, do: year

  defp parse_year(<<year::binary-size(4), _rest::binary>>) do
    case Integer.parse(year) do
      {parsed, ""} when parsed in 1970..3000 -> parsed
      _invalid -> nil
    end
  end

  defp parse_year(_value), do: nil

  defp put_nonempty(map, _key, []), do: map
  defp put_nonempty(map, key, value), do: Map.put(map, key, value)
  defp put_value(map, _key, nil), do: map
  defp put_value(map, key, value), do: Map.put(map, key, value)

  defp put_text(map, key, value) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, 600) do
      "" -> map
      text -> Map.put(map, key, text)
    end
  end

  defp put_text(map, _key, _value), do: map
end
