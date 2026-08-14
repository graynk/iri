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

defmodule Iri.Collections.Export do
  @moduledoc "Formats a private collection for portable CSV and plain-text downloads."

  @csv_headers ["Title", "Release year", "IGDB rating", "My rating", "Comment", "Store links"]

  def csv(entries) do
    rows =
      Enum.map(entries, fn entry ->
        [
          entry.title,
          entry.release_year,
          format_rating(entry.igdb_rating),
          format_rating(entry.personal_rating),
          normalize_comment(entry.comment),
          format_links(entry.store_links)
        ]
      end)

    ([@csv_headers] ++ rows)
    |> Enum.map_join("\r\n", &csv_row/1)
    |> Kernel.<>("\r\n")
  end

  def text(collection, entries) do
    body =
      entries
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {entry, index} ->
        heading = "#{index}. #{entry.title}#{format_year(entry.release_year)}"

        details =
          [normalize_comment(entry.comment)] ++
            Enum.map(entry.store_links, &"#{&1.store}: #{&1.url}")

        ([heading] ++ Enum.reject(details, &is_nil/1))
        |> Enum.join("\n")
      end)

    if body == "", do: "#{collection.name}\n", else: "#{collection.name}\n\n#{body}\n"
  end

  defp csv_row(values), do: Enum.map_join(values, ",", &csv_cell/1)

  defp csv_cell(nil), do: ""

  defp csv_cell(value) do
    value = value |> to_string() |> protect_spreadsheet_formula()
    escaped = String.replace(value, "\"", "\"\"")

    if String.contains?(escaped, [",", "\"", "\r", "\n"]) do
      "\"#{escaped}\""
    else
      escaped
    end
  end

  defp protect_spreadsheet_formula(<<first::utf8, _rest::binary>> = value)
       when first in [?=, ?+, ?-, ?@],
       do: "'#{value}"

  defp protect_spreadsheet_formula(value), do: value

  defp normalize_comment(nil), do: nil

  defp normalize_comment(comment) do
    comment
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp format_links(links), do: Enum.map_join(links, " | ", &"#{&1.store}: #{&1.url}")
  defp format_year(year) when is_integer(year), do: " (#{year})"
  defp format_year(_year), do: ""

  defp format_rating(rating) when is_float(rating),
    do: :erlang.float_to_binary(rating, decimals: 1)

  defp format_rating(rating) when is_integer(rating), do: Integer.to_string(rating)
  defp format_rating(_rating), do: nil
end
