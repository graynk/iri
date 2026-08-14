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

defmodule Iri.Integrations.PSN.Parser do
  @moduledoc "Parses Iri PSN helper exports without retaining Sony credentials."

  @max_bytes 20_000_000
  @max_entries 10_000

  # PSN libraries list media products alongside games: digital artbooks and
  # sketchbooks, soundtracks, themes, avatars, and demo/trial builds. Their
  # names keep a stable trailing marker even on non-English storefronts.
  @non_game_title ~r/[\s(\[–—:-](?:demo(?:version)?|trial|testversion|soundtrack|sketchbook|skizzenbuch|art ?book|kunstbuch|theme|thema|avatar|wallpapers?|hintergr(?:und|ünde))[)\]]?$/iu

  def parse(binary, account_name \\ nil)

  def parse(binary, account_name) when is_binary(binary) and byte_size(binary) <= @max_bytes do
    with {:ok, payload} <- Jason.decode(binary),
         {:ok, account} <- account(payload, account_name),
         {:ok, datasets} <- datasets(payload) do
      entries = datasets |> Enum.flat_map(&dataset_entries/1) |> merge_entries()
      complete? = Enum.any?(datasets, &complete_purchased?/1)
      {:ok, %{account: account, entries: Enum.take(entries, @max_entries), complete?: complete?}}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_psn_export}
    end
  end

  def parse(_binary, _account_name), do: {:error, :file_too_large}

  @doc "Whether an already stored game source would be filtered by the current import rules."
  def non_game_source?(%{source_title: title}) when is_binary(title), do: non_game_title?(title)
  def non_game_source?(_source), do: false

  defp account(%{"schema" => schema, "account" => account}, _fallback)
       when schema in ["iri-psn-export/v1", "iri-psn-export/v2", "iri-psn-export/v3"] and
              is_map(account) do
    id = text(account["id"] || account["account_id"] || account["online_id"] || account["name"])
    name = text(account["online_id"] || account["name"] || id)
    if id, do: {:ok, %{id: id, name: name}}, else: {:error, :missing_account}
  end

  defp account(%{"schema" => schema}, fallback)
       when schema in ["iri-psn-export/v2", "iri-psn-export/v3"] do
    case text(fallback) do
      nil -> {:error, :missing_account}
      name -> {:ok, %{id: String.downcase(name), name: name}}
    end
  end

  defp account(_payload, _fallback), do: {:error, :unsupported_schema}

  defp datasets(%{"datasets" => datasets}) when is_list(datasets), do: {:ok, datasets}
  defp datasets(_payload), do: {:error, :missing_datasets}

  defp dataset_entries(%{"kind" => kind, "items" => items}) when is_list(items) do
    relationship = if kind == "purchased", do: :owned, else: :played
    Enum.flat_map(items, &normalize(&1, relationship))
  end

  defp dataset_entries(_dataset), do: []

  defp complete_purchased?(%{
         "kind" => "purchased",
         "complete" => true,
         "pagination" => %{"final" => true, "pages_observed" => pages}
       })
       when is_integer(pages) and pages > 0,
       do: true

  defp complete_purchased?(_dataset), do: false

  defp merge_entries(entries) do
    entries
    |> Enum.reduce(%{}, fn entry, merged ->
      Map.update(merged, entry.external_id, entry, &merge_entry(&1, entry))
    end)
    |> Map.values()
    |> fold_dom_duplicates()
  end

  # PlayStation exposes different identifiers per list: the played list has
  # numeric concept IDs, the purchased list only title/product IDs, and the
  # DOM fallback synthesizes dom- hashes. Captures of the same title are one
  # game, so fold each group into its best-identified entry.
  defp fold_dom_duplicates(entries) do
    entries
    |> Enum.group_by(&String.downcase(&1.title))
    |> Enum.flat_map(fn {_title, group} ->
      [primary | rest] = Enum.sort_by(group, &entry_id_rank/1, :desc)
      [Enum.reduce(rest, primary, &merge_entry(&2, &1))]
    end)
  end

  defp entry_id_rank(%{external_id: "dom-" <> _rest}), do: 0

  defp entry_id_rank(%{external_id: external_id}) do
    if Regex.match?(~r/^\d+$/, external_id), do: 2, else: 1
  end

  defp non_game_title?(title), do: Regex.match?(@non_game_title, title)

  defp merge_entry(left, right) do
    relationship =
      if left.relationship == :owned or right.relationship == :owned, do: :owned, else: :played

    %{
      left
      | relationship: relationship,
        metadata: Map.merge(left.metadata, right.metadata)
    }
  end

  defp normalize(item, relationship) when is_map(item) do
    id =
      text(
        item["concept_id"] || item["conceptId"] || item["title_id"] || item["titleId"] ||
          item["np_communication_id"] || item["product_id"] || item["productId"]
      )

    title = text(item["name"] || item["titleName"] || item["title"])

    if id && title && not non_game_title?(title) do
      [
        %{
          external_id: id,
          title: title,
          relationship: relationship,
          metadata: %{"psn" => item}
        }
      ]
    else
      []
    end
  end

  defp normalize(_item, _relationship), do: []

  defp text(value) when is_integer(value), do: to_string(value)

  defp text(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp text(_value), do: nil
end
