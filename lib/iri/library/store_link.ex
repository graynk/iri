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

defmodule Iri.Library.StoreLink do
  @moduledoc """
  Builds store-page links from game sources.

  Shared by the collection exports and the game detail page so both surface the
  same links.
  """

  @doc """
  Returns a deduplicated list of `%{store: name, url: url}` for the sources.

  Each source is any struct/map exposing `provider`, `external_id`, and
  `source_url`.
  """
  def for_sources(sources) do
    sources
    |> Enum.flat_map(fn source ->
      case build(source.provider, source.external_id, source.source_url) do
        nil -> []
        link -> [link]
      end
    end)
    |> Enum.uniq_by(& &1.url)
  end

  def build(:steam, external_id, _source_url) when is_binary(external_id) do
    %{store: "Steam", url: "https://store.steampowered.com/app/#{external_id}"}
  end

  def build(:gog, _external_id, source_url) do
    if web_url?(source_url), do: %{store: "GOG", url: source_url}
  end

  def build(provider, _external_id, source_url) do
    if web_url?(source_url) do
      %{store: provider |> Atom.to_string() |> String.upcase(), url: source_url}
    end
  end

  defp web_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _other ->
        false
    end
  end

  defp web_url?(_url), do: false
end
