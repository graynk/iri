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

defmodule Iri.Integrations.IGDB.Matcher do
  @moduledoc "Ranks title-search candidates and identifies the narrow safe auto-match case."

  alias Iri.Integrations.IGDB.TitleSearch
  alias Iri.Integrations.SourceMetadata
  alias Iri.Library.GameSource
  alias Iri.Library.Title

  def rank(source_title, candidates, options \\ []) do
    normalized_source = source_title |> TitleSearch.canonical_title() |> Title.normalize()
    provider = Keyword.get(options, :provider, :steam)

    candidates
    |> Enum.filter(&(is_integer(&1["id"]) and is_binary(&1["name"])))
    |> Enum.map(fn candidate ->
      normalized = candidate["name"] |> TitleSearch.canonical_title() |> Title.normalize()
      exact_title? = normalized == normalized_source
      platform_match? = platform_match?(candidate, provider)

      %{
        igdb_id: candidate["id"],
        title: candidate["name"],
        normalized_title: normalized,
        score: score(normalized_source, normalized, exact_title?, platform_match?),
        metadata: %{
          "summary" => candidate["summary"],
          "first_release_date" => candidate["first_release_date"],
          "game_type" => candidate["game_type"],
          "platforms" => candidate["platforms"] || [],
          "involved_companies" => candidate["involved_companies"] || [],
          "pc" => platform_match?(candidate, :steam),
          "platform_match" => platform_match?,
          "exact_title" => exact_title?
        }
      }
    end)
    |> Enum.sort_by(&{-&1.score, &1.title, &1.igdb_id})
  end

  def automatic_candidate(ranked, options \\ []) do
    perfect =
      Enum.filter(
        ranked,
        &(&1.score == 1.0 and &1.metadata["exact_title"] and &1.metadata["platform_match"])
      )

    case perfect do
      [candidate] -> {:ok, candidate}
      candidates when length(candidates) > 1 -> disambiguate(candidates, options[:source])
      _none -> :review
    end
  end

  defp disambiguate(candidates, %GameSource{} = source) do
    facts = SourceMetadata.facts(source)

    scored = Enum.map(candidates, &{provider_evidence_score(&1, facts), &1})
    best_score = scored |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0 end)
    best = for {score, candidate} <- scored, score == best_score, do: candidate

    case {best_score, best} do
      {score, [candidate]} when score > 0 -> {:ok, candidate}
      _ambiguous -> :review
    end
  end

  defp disambiguate(_candidates, _source), do: :review

  defp provider_evidence_score(candidate, facts) do
    company_score =
      if intersects?(facts["companies"], candidate_companies(candidate)), do: 4, else: 0

    platform_score =
      if intersects?(facts["platforms"], candidate_platforms(candidate), &normalize_platform/1),
        do: 2,
        else: 0

    year_score =
      if facts["release_year"] == candidate_release_year(candidate), do: 1, else: 0

    company_score + platform_score + year_score
  end

  defp candidate_companies(candidate) do
    candidate.metadata["involved_companies"]
    |> List.wrap()
    |> Enum.map(&get_in(&1, ["company", "name"]))
    |> Enum.filter(&is_binary/1)
  end

  defp candidate_platforms(candidate) do
    candidate.metadata["platforms"]
    |> List.wrap()
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
  end

  defp candidate_release_year(candidate) do
    case candidate.metadata["first_release_date"] do
      timestamp when is_integer(timestamp) ->
        case DateTime.from_unix(timestamp) do
          {:ok, datetime} -> datetime.year
          _invalid -> nil
        end

      _value ->
        nil
    end
  end

  defp intersects?(left, right, normalizer \\ &normalize_company/1) do
    left = left |> List.wrap() |> MapSet.new(normalizer)
    right = right |> List.wrap() |> MapSet.new(normalizer)
    not MapSet.disjoint?(left, right)
  end

  defp normalize_company(value) do
    value
    |> Title.normalize()
    |> String.replace(~r/\s+(?:incorporated|inc|llc|ltd|limited|corp|corporation|gmbh)$/u, "")
  end

  defp normalize_platform(value) do
    case Title.normalize(value) do
      platform when platform in ["ps5", "playstation 5"] -> "playstation 5"
      platform when platform in ["ps4", "playstation 4"] -> "playstation 4"
      platform when platform in ["ps3", "playstation 3"] -> "playstation 3"
      platform when platform in ["pc", "windows", "pc microsoft windows"] -> "pc"
      platform -> platform
    end
  end

  defp score(_source, _candidate, true, true), do: 1.0
  defp score(_source, _candidate, true, false), do: 0.95

  defp score(source, candidate, false, pc?) do
    pc_bonus = if pc?, do: 0.05, else: 0.0
    min(String.jaro_distance(source, candidate) * 0.9 + pc_bonus, 0.94)
  end

  defp pc_game?(candidate) do
    candidate
    |> Map.get("platforms", [])
    |> Enum.any?(fn platform ->
      platform["name"] in ["PC (Microsoft Windows)", "Linux", "Mac"]
    end)
  end

  defp platform_match?(candidate, provider) when provider in [:steam, :gog, :epic],
    do: pc_game?(candidate)

  defp platform_match?(candidate, :psn) do
    Enum.any?(Map.get(candidate, "platforms", []), fn platform ->
      name = platform["name"] || ""
      String.starts_with?(name, "PlayStation") or name in ["PS Vita", "PSP"]
    end)
  end

  defp platform_match?(candidate, :xbox) do
    Enum.any?(Map.get(candidate, "platforms", []), fn platform ->
      String.starts_with?(platform["name"] || "", "Xbox")
    end)
  end

  defp platform_match?(candidate, _provider), do: pc_game?(candidate)
end
