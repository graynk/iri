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

defmodule Iri.Integrations.VNDB.Enricher do
  @moduledoc "Creates canonical visual-novel records from exact VNDB store links."

  import Ecto.Query, warn: false

  alias Iri.Integrations.VNDB.Client

  alias Iri.Library.{
    Company,
    Game,
    GameCompany,
    GameSource,
    MediaAsset,
    TaxonomyTerm,
    Title
  }

  alias Iri.Media
  alias Iri.Media.Classification
  alias Iri.Repo

  def enrich_steam_sources(sources, options \\ []) do
    enrich_sources(sources, options)
  end

  def enrich_sources(sources, options \\ []) do
    client = Keyword.get(options, :client, Application.get_env(:iri, :vndb_client, Client))
    client_options = Keyword.get(options, :client_options, [])
    cache_cover = Keyword.get(options, :cache_cover, &Media.cache_cover/2)

    sources = unresolved_sources(sources)

    with {:ok, matches} <- lookup_matches(sources, client, client_options) do
      result =
        Enum.reduce(
          sources,
          %{matched_count: 0, updated_count: 0, failed_count: 0, failures: []},
          fn source, counts ->
            case Map.get(matches, {source.provider, lookup_id(source)}, []) do
              [payload] -> ingest_match(source, payload, cache_cover, options, counts)
              _none_or_ambiguous -> counts
            end
          end
        )

      {:ok, result}
    end
  end

  def ingest_selected_game(%GameSource{} = source, payload, options \\ []) do
    cache_cover = Keyword.get(options, :cache_cover, &Media.cache_cover/2)

    case Repo.transact_with_busy_retry(
           fn -> upsert_and_link(source, payload, "manual_vndb", true) end,
           mode: :immediate
         ) do
      {:ok, game} ->
        _result = cache_cover.(game.id, Keyword.get(options, :media_options, []))
        {:ok, game}

      error ->
        error
    end
  end

  def ingest_game(payload, options \\ []) when is_map(payload) do
    cache_cover = Keyword.get(options, :cache_cover, &Media.cache_cover/2)

    case Repo.transact_with_busy_retry(fn -> upsert_game(payload) end, mode: :immediate) do
      {:ok, game} ->
        _result = cache_cover.(game.id, Keyword.get(options, :media_options, []))
        {:ok, game}

      error ->
        error
    end
  end

  defp unresolved_sources(sources) do
    ids = Enum.map(sources, & &1.id)

    Repo.all(
      from source in GameSource,
        where:
          source.id in ^ids and source.provider in [:steam, :gog] and is_nil(source.game_id) and
            not source.manual_lock,
        order_by: [asc: source.id]
    )
    |> Enum.filter(&(is_binary(lookup_id(&1)) and lookup_id(&1) != ""))
  end

  defp lookup_matches(sources, client, client_options) do
    sources
    |> Enum.group_by(& &1.provider)
    |> Enum.reduce_while({:ok, %{}}, fn {provider, provider_sources}, {:ok, collected} ->
      external_ids = Enum.map(provider_sources, &lookup_id/1)

      case client.lookup_games(provider, external_ids, client_options) do
        {:ok, matches} ->
          keyed =
            Map.new(matches, fn {external_id, games} -> {{provider, external_id}, games} end)

          {:cont, {:ok, Map.merge(collected, keyed)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp lookup_id(%GameSource{provider: :steam, external_id: external_id}), do: external_id

  defp lookup_id(%GameSource{provider: :gog, source_url: source_url})
       when is_binary(source_url) do
    source_url
    |> URI.parse()
    |> Map.get(:path)
    |> to_string()
    |> String.split("/", trim: true)
    |> List.last()
  end

  defp lookup_id(_source), do: nil

  defp match_method(%GameSource{provider: :steam}), do: "vndb_steam_id"
  defp match_method(%GameSource{provider: :gog}), do: "vndb_gog_slug"

  defp ingest_match(source, payload, cache_cover, options, counts) do
    case Repo.transact_with_busy_retry(
           fn -> upsert_and_link(source, payload, match_method(source), false) end,
           mode: :immediate
         ) do
      {:ok, game} ->
        _result = cache_cover.(game.id, Keyword.get(options, :media_options, []))

        %{
          counts
          | matched_count: counts.matched_count + 1,
            updated_count: counts.updated_count + 1
        }

      {:error, reason} ->
        %{
          counts
          | failed_count: counts.failed_count + 1,
            failures:
              Enum.take(
                counts.failures ++
                  [
                    %{
                      kind: "vndb_ingest_failed",
                      message:
                        "#{source.source_title}: VNDB metadata could not be saved (#{failure_message(reason)})",
                      retryable: true
                    }
                  ],
                20
              )
        }
    end
  end

  defp upsert_and_link(
         source,
         %{"id" => vndb_id, "title" => title} = payload,
         match_method,
         manual_lock
       )
       when is_binary(vndb_id) and is_binary(title) do
    with {:ok, game} <- upsert_game(payload),
         {:ok, _source} <-
           source
           |> GameSource.changeset(%{
             game_id: game.id,
             match_method: match_method,
             manual_lock: manual_lock,
             nsfw: nsfw?(payload)
           })
           |> Repo.update() do
      {:ok, game}
    end
  end

  defp upsert_and_link(_source, _payload, _match_method, _manual_lock),
    do: {:error, :invalid_vndb_game}

  defp upsert_game(%{"id" => vndb_id, "title" => title} = payload)
       when is_binary(vndb_id) and is_binary(title) do
    game = Repo.get_by(Game, vndb_id: vndb_id) || %Game{}
    date = partial_date(payload["released"])
    automatically_nsfw? = nsfw?(payload)

    attrs = %{
      vndb_id: vndb_id,
      nsfw: automatically_nsfw?,
      title: title,
      normalized_title: Title.normalize(title),
      slug: "#{Title.slug(title)}-vndb-#{vndb_id}",
      summary: payload["description"],
      release_date: date,
      release_year: date && date.year,
      rating: number(payload["rating"])
    }

    attrs =
      if Classification.manually_classified?(game),
        do: Map.delete(attrs, :nsfw),
        else: attrs

    with {:ok, game} <- game |> Game.changeset(attrs) |> Repo.insert_or_update(),
         :ok <- replace_companies(game, payload),
         :ok <- replace_terms(game, payload),
         :ok <- replace_media(game, payload) do
      {:ok, game}
    end
  end

  defp upsert_game(_payload),
    do: {:error, :invalid_vndb_game}

  defp replace_companies(game, payload) do
    Repo.delete_all(from company in GameCompany, where: company.game_id == ^game.id)

    Enum.each(payload["developers"] || [], fn developer ->
      if is_binary(developer["id"]) and is_binary(developer["name"]) do
        company =
          (Repo.get_by(Company, source: "vndb", external_id: developer["id"]) || %Company{})
          |> Company.changeset(%{
            source: "vndb",
            external_id: developer["id"],
            name: developer["name"],
            slug: Title.slug(developer["name"])
          })
          |> Repo.insert_or_update!()

        %GameCompany{}
        |> GameCompany.changeset(%{game_id: game.id, company_id: company.id, role: "developer"})
        |> Repo.insert!(on_conflict: :nothing)
      end
    end)

    :ok
  end

  defp replace_terms(game, payload) do
    terms =
      payload
      |> Map.get("tags", [])
      |> Enum.filter(&((&1["spoiler"] || 0) == 0 and number(&1["rating"]) >= 1.0))

    Enum.each(terms, fn tag ->
      term =
        (Repo.get_by(TaxonomyTerm,
           source: "vndb",
           kind: "keyword",
           external_id: tag["id"]
         ) || %TaxonomyTerm{})
        |> TaxonomyTerm.changeset(%{
          source: "vndb",
          external_id: tag["id"],
          kind: "keyword",
          name: tag["name"],
          slug: Title.slug(tag["name"])
        })
        |> Repo.insert_or_update!()

      Repo.insert_all("game_terms", [%{game_id: game.id, taxonomy_term_id: term.id}],
        on_conflict: :nothing
      )
    end)

    :ok
  end

  defp replace_media(game, payload) do
    screenshots =
      (payload["screenshots"] || [])
      |> Enum.with_index()
      |> Enum.map(fn {image, index} -> media_attrs(game, image, "screenshot", index) end)

    desired =
      [media_attrs(game, payload["image"], "cover", 0) | screenshots]
      |> Enum.reject(&is_nil/1)

    desired_keys = Enum.map(desired, &{&1.kind, &1.remote_id})

    Repo.all(
      from asset in MediaAsset,
        where: asset.game_id == ^game.id and asset.source == "vndb"
    )
    |> Enum.reject(&({&1.kind, &1.remote_id} in desired_keys))
    |> Enum.each(&Repo.delete!/1)

    Enum.each(desired, fn attrs ->
      asset =
        Repo.get_by(MediaAsset,
          game_id: game.id,
          source: "vndb",
          kind: attrs.kind,
          remote_id: attrs.remote_id
        ) || %MediaAsset{}

      attrs =
        if asset.id && asset.cache_status == "ready" do
          Map.delete(attrs, :cache_status)
        else
          attrs
        end

      asset
      |> MediaAsset.changeset(attrs)
      |> Repo.insert_or_update!()
    end)

    :ok
  end

  defp media_attrs(_game, nil, _kind, _position), do: nil

  defp media_attrs(game, image, kind, position) do
    url = image["url"] || image["thumbnail"]

    if is_binary(image["id"]) and is_binary(url) do
      %{
        game_id: game.id,
        kind: kind,
        source: "vndb",
        remote_id: image["id"],
        remote_url: url,
        position: position,
        cache_status: "remote"
      }
    end
  end

  defp nsfw?(payload) do
    release = payload["_release"] || %{}

    release["has_ero"] == true or
      sexual?(payload["image"]) or
      Enum.any?(payload["screenshots"] || [], &sexual?/1) or
      Enum.any?(payload["tags"] || [], &(&1["category"] == "ero"))
  end

  defp sexual?(%{"sexual" => value}) when is_number(value), do: value >= 1.0
  defp sexual?(_image), do: false

  defp partial_date(value) when is_binary(value) do
    case value do
      <<year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2)>> ->
        with {year, ""} <- Integer.parse(year),
             {month, ""} <- Integer.parse(month),
             {day, ""} <- Integer.parse(day),
             {:ok, date} <- Date.new(year, month, day),
             do: date

      <<year::binary-size(4), "-", month::binary-size(2)>> ->
        with {year, ""} <- Integer.parse(year),
             {month, ""} <- Integer.parse(month),
             {:ok, date} <- Date.new(year, month, 1),
             do: date

      <<year::binary-size(4)>> ->
        with {year, ""} <- Integer.parse(year), {:ok, date} <- Date.new(year, 1, 1), do: date

      _other ->
        nil
    end
  end

  defp partial_date(_value), do: nil
  defp number(value) when is_integer(value), do: value / 1
  defp number(value) when is_float(value), do: value
  defp number(_value), do: 0.0

  defp failure_message(%Iri.Integrations.Error{message: message}), do: message
  defp failure_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_message(_reason), do: "unexpected error"
end
