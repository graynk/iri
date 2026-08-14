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

defmodule Iri.Library.Title do
  @moduledoc "Stable title normalization and source-slug generation."

  @ownership_marks ~r/[™®©℠℗ⓇⒸ]/u
  @ownership_annotations ~r/[\(\[\{]\s*(?:tm|r|c|sm)\s*[\)\]\}]/iu
  @invisible_formatting ["\u200B", "\u200C", "\u200D", "\u2060", "\uFEFF", "\u00AD"]

  def normalize(title) when is_binary(title) do
    title
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  def slug(title) when is_binary(title) do
    title
    |> normalize()
    |> String.replace(" ", "-")
    |> String.slice(0, 180)
  end

  @doc """
  Removes storefront ownership marks and invisible formatting before a title is
  sent to an external metadata search.

  This intentionally preserves meaningful punctuation and does not replace the
  original source title used for display and candidate scoring.
  """
  def for_provider_search(title) when is_binary(title) do
    title
    |> String.replace(@ownership_marks, "")
    |> String.replace(@ownership_annotations, " ")
    |> then(fn title ->
      Enum.reduce(@invisible_formatting, title, &String.replace(&2, &1, ""))
    end)
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  def for_provider_search(_title), do: ""
end
