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

defmodule Iri.AI.CandidateBuilder do
  @moduledoc "Builds the bounded, sanitized catalog choices sent to an AI provider."

  alias Iri.AI.MatchRequest
  alias Iri.Integrations
  alias Iri.Integrations.IGDB.{Client, Matcher, TitleSearch}
  alias Iri.Integrations.SourceMetadata
  alias Iri.Integrations.VNDB.Client, as: VNDBClient
  alias Iri.Library.{GameSource, MatchCandidate, Title}
  alias Iri.Repo

  def build(%GameSource{} = source, options \\ []) do
    source = Repo.preload(source, :match_candidates, force: true)

    with {:ok, igdb_candidates} <- igdb_candidates(source, options) do
      vndb_candidates = vndb_candidates(source, options)

      {:ok, build_request(source, igdb_candidates ++ vndb_candidates, [], [])}
    end
  end

  def search(%GameSource{} = source, %MatchRequest{} = request, query, options \\ []) do
    query = query |> Title.for_provider_search() |> String.slice(0, 120)

    with false <- query == "",
         {:ok, igdb_candidates} <- searched_igdb_candidates(source, query, options) do
      vndb_candidates = vndb_candidates(source, query, options)
      searched = igdb_candidates ++ vndb_candidates
      candidates = merge_candidates(searched, request.candidates)
      search_queries = request.search_queries ++ [query]

      search_attempts =
        request.search_attempts ++
          [%{"query" => query, "candidate_count" => length(searched)}]

      {:ok, build_request(source, candidates, search_queries, search_attempts)}
    else
      true -> {:error, :invalid_search}
      error -> error
    end
  end

  def source_fingerprint(%GameSource{} = source) do
    candidate_signature =
      case source.match_candidates do
        %Ecto.Association.NotLoaded{} ->
          []

        candidates when is_list(candidates) ->
          Enum.map(candidates, &{&1.igdb_id, &1.title, &1.score})
      end

    hash(%{
      "provider" => Atom.to_string(source.provider),
      "external_id" => source.external_id,
      "title" => source.source_title,
      "metadata" => SourceMetadata.facts(source),
      "candidate_signature" => candidate_signature
    })
  end

  defp igdb_candidates(%GameSource{match_candidates: candidates}, _options)
       when candidates != [] do
    {:ok, Enum.map(candidates, &igdb_candidate/1)}
  end

  defp igdb_candidates(source, options) do
    searched_igdb_candidates(source, source.source_title, options)
  end

  defp searched_igdb_candidates(source, query, options) do
    client =
      Keyword.get(options, :igdb_client, Application.get_env(:iri, :igdb_client, Client))

    client_options = Keyword.get(options, :igdb_options, [])

    with {:ok, credentials} <- Integrations.igdb_credentials_for_sync(client, client_options),
         {:ok, games} <-
           TitleSearch.search(client, credentials, query, client_options) do
      {:ok,
       query
       |> Matcher.rank(games, provider: source.provider)
       |> Enum.map(&igdb_candidate/1)}
    end
  end

  defp vndb_candidates(source, options) do
    vndb_candidates(source, source.source_title, options)
  end

  defp vndb_candidates(_source, query, options) do
    client =
      Keyword.get(options, :vndb_client, Application.get_env(:iri, :vndb_client, VNDBClient))

    case client.search_games(query, Keyword.get(options, :vndb_options, [])) do
      {:ok, candidates} -> Enum.map(candidates, &vndb_candidate/1)
      {:error, _reason} -> []
    end
  end

  defp build_request(source, candidates, search_queries, search_attempts) do
    candidates = candidates |> bounded_candidates() |> assign_keys()
    source_payload = source_payload(source)

    %MatchRequest{
      source: source_payload,
      candidates: candidates,
      search_queries: search_queries,
      search_attempts: search_attempts
    }
  end

  defp merge_candidates(searched, existing) do
    (searched ++ Enum.map(existing, &Map.delete(&1, "key")))
    |> Enum.uniq_by(&{&1["catalog"], &1["external_id"]})
  end

  defp bounded_candidates(candidates) do
    for catalog <- ["igdb", "vndb"],
        candidate <- candidates |> Enum.filter(&(&1["catalog"] == catalog)) |> Enum.take(10),
        do: candidate
  end

  defp assign_keys(candidates) do
    candidates
    |> Enum.with_index(1)
    |> Enum.map(fn {candidate, index} ->
      Map.put(
        candidate,
        "key",
        "candidate_#{index |> Integer.to_string() |> String.pad_leading(2, "0")}"
      )
    end)
  end

  defp source_payload(source) do
    %{
      "provider" => Atom.to_string(source.provider),
      "external_id" => source.external_id,
      "title" => source.source_title,
      "source_url" => source.source_url,
      "catalog_kind" => source.catalog_kind,
      "metadata" => SourceMetadata.facts(source)
    }
  end

  defp igdb_candidate(%MatchCandidate{} = candidate) do
    igdb_candidate(%{
      igdb_id: candidate.igdb_id,
      title: candidate.title,
      score: candidate.score,
      metadata: candidate.metadata || %{}
    })
  end

  defp igdb_candidate(candidate) do
    metadata = candidate.metadata || %{}

    %{
      "catalog" => "igdb",
      "external_id" => to_string(candidate.igdb_id),
      "title" => candidate.title,
      "alternate_titles" => [],
      "release_year" => unix_year(metadata["first_release_date"]),
      "type" => get_in(metadata, ["game_type", "type"]),
      "platforms" => names(metadata["platforms"]),
      "developers" => igdb_companies(metadata, "developer"),
      "publishers" => igdb_companies(metadata, "publisher"),
      "summary" => short_text(metadata["summary"]),
      "deterministic_score" => candidate.score
    }
  end

  defp vndb_candidate(candidate) do
    %{
      "catalog" => "vndb",
      "external_id" => candidate["id"],
      "title" => candidate["title"],
      "alternate_titles" =>
        ([candidate["alttitle"]] ++
           Enum.map(candidate["titles"] || [], &(&1["latin"] || &1["title"])))
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.take(10),
      "release_year" => partial_year(candidate["released"]),
      "type" => "Visual Novel",
      "platforms" => Enum.filter(candidate["platforms"] || [], &is_binary/1),
      "developers" => names(candidate["developers"]),
      "publishers" => [],
      "summary" => short_text(candidate["description"]),
      "deterministic_score" => nil
    }
  end

  defp igdb_companies(metadata, role) do
    metadata["involved_companies"] ||
      []
      |> Enum.filter(&(&1[role] == true))
      |> Enum.map(&get_in(&1, ["company", "name"]))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
  end

  defp names(values) when is_list(values) do
    values
    |> Enum.map(fn
      %{"name" => name} -> name
      name when is_binary(name) -> name
      _value -> nil
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp names(_values), do: []

  defp unix_year(timestamp) when is_integer(timestamp) do
    case DateTime.from_unix(timestamp) do
      {:ok, datetime} -> datetime.year
      _error -> nil
    end
  end

  defp unix_year(_timestamp), do: nil

  defp partial_year(<<year::binary-size(4), _rest::binary>>) do
    case Integer.parse(year) do
      {year, ""} -> year
      _invalid -> nil
    end
  end

  defp partial_year(_date), do: nil

  defp short_text(value) when is_binary(value), do: value |> String.trim() |> String.slice(0, 600)
  defp short_text(_value), do: nil

  defp hash(value) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(value, [:deterministic])
    )
    |> Base.encode16(case: :lower)
  end
end
