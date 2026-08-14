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

defmodule Iri.Integrations.IGDB.TitleSearch do
  @moduledoc "Builds store-title fallbacks and searches IGDB without promotional title noise."

  alias Iri.Library.Title

  # Packaging labels can safely fall back to the base game. "Definitive
  # Edition" is deliberately absent: stores and IGDB often use it for a
  # distinct remake or remaster, as with Mafia: Definitive Edition.
  @edition_suffix ~r/\s*(?:[-:–—]\s*)?(?:(?:game\s+of\s+the\s+year|goty|complete|ultimate|deluxe|gold|enhanced)\s+edition)\s*$/iu
  @marketing_suffixes [
    ~r/\s*:\s*post[- ]apocalyptic\s+indie\s+game\s*$/iu
  ]

  def search(client, credentials, title, options \\ []) do
    title
    |> terms()
    |> Enum.reduce_while({:ok, []}, fn term, _empty_result ->
      case client.search_games(credentials, term, options) do
        {:ok, []} -> {:cont, {:ok, []}}
        {:ok, candidates} -> {:halt, {:ok, candidates}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def terms(title) when is_binary(title) do
    cleaned = clean(title)
    canonical = canonical_title(cleaned)
    separator_variant = String.replace(canonical, ~r/\s+[-–—]\s+/u, ": ")
    punctuation_fallback = punctuation_fallback(canonical)

    [canonical, cleaned, separator_variant, punctuation_fallback]
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def terms(_title), do: []

  def canonical_title(title) when is_binary(title) do
    title
    |> clean()
    |> strip_marketing_suffixes()
    |> then(&Regex.replace(@edition_suffix, &1, ""))
    |> clean()
  end

  def canonical_title(_title), do: ""

  defp strip_marketing_suffixes(title) do
    Enum.reduce(@marketing_suffixes, title, &Regex.replace(&1, &2, ""))
  end

  defp clean(title) do
    Title.for_provider_search(title)
  end

  defp punctuation_fallback(title) do
    title
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
