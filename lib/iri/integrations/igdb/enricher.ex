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

defmodule Iri.Integrations.IGDB.Enricher do
  @moduledoc "Exact external-ID matching and transactional projection of IGDB metadata."

  import Ecto.Query, warn: false

  alias Iri.Integrations.IGDB.{Client, Matcher, TitleSearch}
  alias Iri.Integrations.VNDB.Enricher, as: VNDBEnricher

  alias Iri.Library.{
    Company,
    Game,
    GameCompany,
    GameSource,
    MatchCandidate,
    MediaAsset,
    TaxonomyTerm,
    Title
  }

  alias Iri.Media
  alias Iri.Media.Classification
  alias Iri.Repo

  @batch_size 400
  @ingest_batch_size 10

  def enrich(credentials, options \\ []) do
    client = Keyword.get(options, :client, Client)
    client_options = Keyword.get(options, :client_options, [])
    cache_cover = Keyword.get(options, :cache_cover, &Media.cache_cover/2)
    progress = Keyword.get(options, :progress, fn _step, _details -> :ok end)
    force? = Keyword.get(options, :force, false)
    provider_account_id = Keyword.get(options, :provider_account_id)

    with sources <- eligible_sources(provider_account_id, force?),
         {:ok, source_ids} <- source_ids_for(sources, credentials),
         {:ok, mapping_result} <-
           map_sources(sources, source_ids, credentials, client, client_options),
         :ok <-
           progress.("external_ids_complete", %{
             "sources" => length(sources),
             "exact" => map_size(mapping_result.exact)
           }),
         external_exact <- mapping_result.exact,
         external_methods <- mapping_result.methods,
         external_ids <- external_exact |> Map.values() |> Enum.uniq(),
         {:ok, external_result} <-
           resolve_games(external_ids, credentials, client, client_options, force?),
         :ok <- link_exact_sources(external_exact, external_methods, external_result.games),
         :ok <-
           progress.("external_metadata_complete", %{
             "games" => map_size(external_result.updated),
             "failed" => external_result.failed_count
           }),
         {:ok, mapping_result} <-
           match_unmapped_titles(mapping_result, credentials, client, client_options),
         :ok <-
           progress.("title_fallback_complete", %{
             "matched" => map_size(mapping_result.exact),
             "unresolved" => mapping_result.unmatched_count + mapping_result.ambiguous_count
           }),
         fallback_exact <- Map.drop(mapping_result.exact, Map.keys(external_exact)),
         fallback_methods <- Map.take(mapping_result.methods, Map.keys(fallback_exact)),
         fallback_ids <- fallback_exact |> Map.values() |> Enum.uniq(),
         {:ok, fallback_result} <-
           resolve_games(fallback_ids, credentials, client, client_options, force?),
         :ok <- link_exact_sources(fallback_exact, fallback_methods, fallback_result.games),
         vndb_result <-
           run_vndb_fallback(sources,
             client:
               Keyword.get(
                 options,
                 :vndb_client,
                 Application.get_env(
                   :iri,
                   :vndb_client,
                   Iri.Integrations.VNDB.Client
                 )
               ),
             client_options: Keyword.get(options, :vndb_client_options, []),
             cache_cover: cache_cover,
             media_options: Keyword.get(options, :media_options, [])
           ),
         updated <- Map.merge(external_result.updated, fallback_result.updated),
         :ok <-
           progress.("metadata_complete", %{
             "games" => map_size(updated) + vndb_result.updated_count
           }),
         covers_to_cache <-
           (Map.values(updated) ++ pending_remote_cover_games())
           |> Map.new(&{&1.id, &1})
           |> Map.values(),
         cache_counts <- cache_covers(covers_to_cache, cache_cover, options),
         {:ok, screenshot_counts} <- cache_screenshots(options, progress) do
      {:ok,
       %{
         source_ids: Enum.map(sources, & &1.id),
         discovered_count: length(sources),
         matched_count: map_size(mapping_result.exact) + vndb_result.matched_count,
         unmatched_count:
           max(
             mapping_result.unmatched_count + mapping_result.ambiguous_count -
               vndb_result.matched_count,
             0
           ),
         updated_count: map_size(updated) + vndb_result.updated_count,
         failed_count:
           mapping_result.failed_count + external_result.failed_count +
             fallback_result.failed_count + vndb_result.failed_count + cache_counts.failed +
             screenshot_counts.failed,
         cached_count: cache_counts.cached,
         screenshots_cached_count: screenshot_counts.cached,
         screenshots_failed_count: screenshot_counts.failed,
         failures:
           (mapping_result.failures ++
              external_result.failures ++
              fallback_result.failures ++
              vndb_result.failures ++
              cache_counts.failures ++
              screenshot_counts.failures)
           |> Enum.take(20)
       }}
    end
  end

  def ingest_selected_game(game_payload) when is_map(game_payload) do
    Repo.transact_with_busy_retry(fn -> upsert_game(game_payload) end, mode: :immediate)
  end

  defp run_vndb_fallback(sources, options) do
    case VNDBEnricher.enrich_sources(sources, options) do
      {:ok, result} ->
        Map.put_new(result, :failures, [])

      {:error, reason} ->
        %{
          matched_count: 0,
          updated_count: 0,
          failed_count: 1,
          failures: [
            %{
              kind: "vndb_lookup_failed",
              message: "VNDB fallback could not be checked (#{failure_message(reason)})",
              retryable: retryable?(reason)
            }
          ]
        }
    end
  end

  defp eligible_sources(provider_account_id, force?) do
    query =
      from source in GameSource,
        join: item in assoc(source, :library_items),
        join: account in assoc(item, :provider_account),
        where:
          source.provider in [:steam, :gog, :epic, :psn, :xbox] and not source.manual_lock and
            not item.hidden and is_nil(item.removed_at) and account.enabled and
            (is_nil(source.catalog_kind) or source.catalog_kind in ["game", "unknown"]),
        distinct: true,
        order_by: [asc: source.id],
        preload: [:game]

    query =
      if is_integer(provider_account_id) do
        from [source, item, account] in query, where: account.id == ^provider_account_id
      else
        query
      end

    query =
      if force? do
        query
      else
        from [source, item, account] in query, where: is_nil(source.game_id)
      end

    Repo.all(query)
  end

  defp source_ids_for(sources, credentials) do
    sources
    |> Enum.map(& &1.provider)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn provider, {:ok, source_ids} ->
      case credentials[source_id_key(provider)] do
        source_id when is_integer(source_id) ->
          {:cont, {:ok, Map.put(source_ids, provider, source_id)}}

        _value ->
          {:cont, {:ok, source_ids}}
      end
    end)
  end

  defp source_id_key(:steam), do: "steam_source_id"
  defp source_id_key(:gog), do: "gog_source_id"
  defp source_id_key(:epic), do: "epic_source_id"
  defp source_id_key(:psn), do: "psn_source_id"
  defp source_id_key(:xbox), do: "xbox_source_id"

  defp map_sources(sources, source_ids, credentials, client, client_options) do
    sources
    |> Enum.group_by(& &1.provider)
    |> Enum.sort_by(fn {provider, _sources} -> provider end)
    |> Enum.reduce_while({:ok, empty_mapping_result()}, fn {provider, provider_sources},
                                                           {:ok, acc} ->
      case Map.fetch(source_ids, provider) do
        {:ok, source_id} ->
          case map_source_chunks(
                 provider_sources,
                 source_id,
                 credentials,
                 client,
                 client_options,
                 acc
               ) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        :error ->
          {:cont, {:ok, %{acc | unmapped: provider_sources ++ acc.unmapped}}}
      end
    end)
  end

  defp map_source_chunks(sources, source_id, credentials, client, client_options, initial) do
    Enum.reduce_while(
      Enum.chunk_every(sources, @batch_size),
      {:ok, initial},
      fn chunk, {:ok, acc} ->
        uids = Enum.map(chunk, & &1.external_id)

        case client.external_games(credentials, source_id, uids, client_options) do
          {:ok, mappings} ->
            grouped = Enum.group_by(mappings, &to_string(&1["uid"]))

            next =
              Enum.reduce(chunk, acc, fn source, result ->
                apply_mapping(source, Map.get(grouped, source.external_id, []), result)
              end)

            {:cont, {:ok, next}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    )
  end

  defp empty_mapping_result do
    %{
      exact: %{},
      methods: %{},
      unmapped: [],
      unmatched_count: 0,
      ambiguous_count: 0,
      failed_count: 0,
      failures: []
    }
  end

  defp apply_mapping(source, [], result) do
    case source.game do
      %{igdb_id: igdb_id} when is_integer(igdb_id) ->
        %{
          result
          | exact: Map.put(result.exact, source.id, igdb_id),
            methods: Map.put(result.methods, source.id, source.match_method || "preserved")
        }

      _game ->
        %{result | unmapped: [source | result.unmapped]}
    end
  end

  defp apply_mapping(source, mappings, result) do
    game_ids = mappings |> Enum.map(& &1["game"]) |> Enum.filter(&is_integer/1) |> Enum.uniq()

    case game_ids do
      [igdb_id] ->
        persist_match_state!(source, [], "external_id")

        %{
          result
          | exact: Map.put(result.exact, source.id, igdb_id),
            methods: Map.put(result.methods, source.id, "external_id")
        }

      [] ->
        apply_mapping(source, [], result)

      _many ->
        persist_mapping_candidates(source, mappings, "ambiguous")
        %{result | ambiguous_count: result.ambiguous_count + 1}
    end
  end

  defp match_unmapped_titles(result, credentials, client, client_options) do
    Enum.reduce_while(result.unmapped, {:ok, %{result | unmapped: []}}, fn source,
                                                                           {:ok, current} ->
      case TitleSearch.search(
             client,
             credentials,
             source.source_title,
             client_options
           ) do
        {:ok, candidates} ->
          ranked = Matcher.rank(source.source_title, candidates, provider: source.provider)

          case Matcher.automatic_candidate(ranked, source: source) do
            {:ok, candidate} ->
              persist_match_state!(source, [], "title_exact_pc")

              {:cont,
               {:ok,
                %{
                  current
                  | exact: Map.put(current.exact, source.id, candidate.igdb_id),
                    methods: Map.put(current.methods, source.id, "title_exact_pc")
                }}}

            :review ->
              method = if ranked == [], do: "unmatched", else: "ambiguous"
              persist_search_candidates(source, ranked, method)

              {:cont, {:ok, %{current | unmatched_count: current.unmatched_count + 1}}}
          end

        {:error, %Iri.Integrations.Error{retryable: true} = error} ->
          persist_match_state!(source, [], "lookup_failed")

          {:cont,
           {:ok,
            %{
              current
              | unmatched_count: current.unmatched_count + 1,
                failed_count: current.failed_count + 1,
                failures:
                  add_failure(current.failures, %{
                    kind: "lookup_failed",
                    message:
                      "#{source.source_title} (#{source.provider} #{source.external_id}): #{error.message}",
                    retryable: true
                  })
            }}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_search_candidates(source, ranked, method) do
    now = DateTime.utc_now(:second)

    rows =
      Enum.map(ranked, fn candidate ->
        %{
          game_source_id: source.id,
          igdb_id: candidate.igdb_id,
          title: candidate.title,
          score: candidate.score,
          metadata: candidate.metadata,
          inserted_at: now,
          updated_at: now
        }
      end)

    persist_match_state!(source, rows, method)
  end

  defp persist_mapping_candidates(source, mappings, method) do
    now = DateTime.utc_now(:second)

    rows =
      mappings
      |> Enum.uniq_by(& &1["game"])
      |> Enum.filter(&is_integer(&1["game"]))
      |> Enum.map(fn mapping ->
        title = mapping["name"] || source.source_title

        %{
          game_source_id: source.id,
          igdb_id: mapping["game"],
          title: title,
          normalized_title: Title.normalize(title),
          score: 1.0,
          metadata: %{"method" => "external_id"},
          inserted_at: now,
          updated_at: now
        }
      end)

    persist_match_state!(source, rows, method)
  end

  defp persist_match_state!(source, rows, method) do
    {:ok, :stored} =
      Repo.transact_with_busy_retry(
        fn ->
          Repo.delete_all(
            from candidate in MatchCandidate, where: candidate.game_source_id == ^source.id
          )

          Repo.insert_all(MatchCandidate, rows, on_conflict: :nothing)

          source
          |> GameSource.changeset(%{match_method: method})
          |> Repo.update!()

          {:ok, :stored}
        end,
        mode: :immediate
      )

    :ok
  end

  defp resolve_games(ids, credentials, client, client_options, force?) do
    ids = Enum.filter(ids, &is_integer/1)
    existing = existing_games(ids)

    fetch_ids =
      if force? do
        ids
      else
        Enum.reject(ids, &Map.has_key?(existing, &1))
      end

    with {:ok, fetch} <- fetch_games(fetch_ids, credentials, client, client_options),
         {:ok, updated} <- ingest_games(fetch.games) do
      {:ok,
       %{
         games: Map.merge(existing, updated),
         updated: updated,
         failed_count: fetch.failed_count,
         failures: fetch.failures
       }}
    end
  end

  defp existing_games([]), do: %{}

  defp existing_games(ids) do
    Repo.all(from game in Game, where: game.igdb_id in ^ids)
    |> Map.new(&{&1.igdb_id, &1})
  end

  defp fetch_games(ids, credentials, client, client_options) do
    Enum.reduce_while(
      Enum.chunk_every(ids, @batch_size),
      {:ok, %{games: [], failed_count: 0, failures: []}},
      fn chunk, {:ok, acc} ->
        case client.games(credentials, chunk, client_options) do
          {:ok, games} ->
            {:cont, {:ok, %{acc | games: acc.games ++ games}}}

          {:error, %Iri.Integrations.Error{retryable: true} = error} ->
            failure = %{
              kind: "metadata_fetch_failed",
              message:
                "IGDB could not fetch #{length(chunk)} matched game records: #{error.message}",
              retryable: true
            }

            {:cont,
             {:ok,
              %{
                acc
                | failed_count: acc.failed_count + length(chunk),
                  failures: add_failure(acc.failures, failure)
              }}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    )
  end

  defp ingest_games(games) do
    games
    |> Enum.chunk_every(@ingest_batch_size)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, accumulated} ->
      case ingest_batch(batch) do
        {:ok, ingested} -> {:cont, {:ok, Map.merge(accumulated, ingested)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ingest_batch(games) do
    Repo.transact_with_busy_retry(
      fn ->
        Enum.reduce_while(games, {:ok, %{}}, fn payload, {:ok, current} ->
          case upsert_game(payload) do
            {:ok, game} -> {:cont, {:ok, Map.put(current, game.igdb_id, game)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end,
      mode: :immediate
    )
  end

  defp upsert_game(%{"id" => igdb_id, "name" => title} = payload)
       when is_integer(igdb_id) and is_binary(title) do
    game = Repo.get_by(Game, igdb_id: igdb_id) || %Game{}
    attrs = game_attrs(game, payload)

    with {:ok, game} <- game |> Game.changeset(attrs) |> Repo.insert_or_update(),
         :ok <- replace_terms(game, payload),
         :ok <- replace_companies(game, payload),
         :ok <- replace_media(game, payload) do
      {:ok, game}
    end
  end

  defp upsert_game(_payload), do: {:error, :invalid_game_payload}

  defp game_attrs(game, payload) do
    title = payload["name"]
    release_date = unix_date(payload["first_release_date"])
    time_to_beat = payload["time_to_beat"] || %{}

    attrs = %{
      igdb_id: payload["id"],
      nsfw: erotic_theme?(payload),
      title: title,
      normalized_title: Title.normalize(title),
      slug: "#{Title.slug(title)}-#{payload["id"]}",
      summary: payload["summary"],
      release_date: release_date,
      release_year: release_date && release_date.year,
      rating: number(payload["total_rating"]),
      time_to_beat_main_seconds: non_negative_integer(time_to_beat["hastily"]),
      time_to_beat_extra_seconds: non_negative_integer(time_to_beat["normally"])
    }

    if Classification.manually_classified?(game), do: Map.delete(attrs, :nsfw), else: attrs
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp replace_terms(game, payload) do
    definitions = [
      {"genres", "genre"},
      {"themes", "theme"},
      {"keywords", "keyword"},
      {"game_modes", "game_mode"},
      {"player_perspectives", "player_perspective"},
      {"platforms", "platform"}
    ]

    terms =
      Enum.flat_map(definitions, fn {field, kind} ->
        payload |> Map.get(field, []) |> Enum.map(&term_attrs(&1, kind))
      end)

    Enum.each(terms, fn attrs ->
      (Repo.get_by(TaxonomyTerm, source: "igdb", kind: attrs.kind, external_id: attrs.external_id) ||
         %TaxonomyTerm{})
      |> TaxonomyTerm.changeset(Map.from_struct(attrs))
      |> Repo.insert_or_update!()
    end)

    term_ids =
      Enum.map(terms, fn attrs ->
        Repo.get_by!(TaxonomyTerm,
          source: "igdb",
          kind: attrs.kind,
          external_id: attrs.external_id
        ).id
      end)

    Repo.delete_all(from join in "game_terms", where: field(join, :game_id) == ^game.id)

    Repo.insert_all(
      "game_terms",
      Enum.map(Enum.uniq(term_ids), &%{game_id: game.id, taxonomy_term_id: &1}),
      on_conflict: :nothing
    )

    :ok
  end

  defp term_attrs(%{"id" => id, "name" => name} = term, kind) do
    %TaxonomyTerm{
      source: "igdb",
      external_id: to_string(id),
      kind: kind,
      name: name,
      slug: term["slug"] || Title.slug(name)
    }
  end

  defp replace_companies(game, payload) do
    Repo.delete_all(from relation in GameCompany, where: relation.game_id == ^game.id)

    payload
    |> Map.get("involved_companies", [])
    |> Enum.flat_map(fn involvement ->
      Enum.map(roles(involvement), &{involvement["company"], &1})
    end)
    |> Enum.filter(fn {company, _role} ->
      match?(%{"id" => id, "name" => name} when is_integer(id) and is_binary(name), company)
    end)
    |> Enum.uniq_by(fn {company, role} -> {company["id"], role} end)
    |> Enum.each(fn {%{"id" => id, "name" => name} = company_payload, role} ->
      company =
        (Repo.get_by(Company, source: "igdb", external_id: to_string(id)) || %Company{})
        |> Company.changeset(%{
          source: "igdb",
          external_id: to_string(id),
          name: name,
          slug: company_payload["slug"] || Title.slug(name)
        })
        |> Repo.insert_or_update!()

      %GameCompany{}
      |> GameCompany.changeset(%{game_id: game.id, company_id: company.id, role: role})
      |> Repo.insert!()
    end)

    :ok
  end

  defp replace_media(game, payload) do
    desired = media_attrs(payload) |> Enum.with_index()

    desired_keys =
      Enum.map(desired, fn {attrs, _position} -> {attrs.kind, attrs.remote_id} end)

    Repo.all(
      from asset in MediaAsset,
        where: asset.game_id == ^game.id and asset.source == "igdb"
    )
    |> Enum.reject(&({&1.kind, &1.remote_id} in desired_keys))
    |> Enum.each(&Repo.delete!/1)

    Enum.each(desired, fn {attrs, position} ->
      asset =
        Repo.get_by(MediaAsset,
          game_id: game.id,
          source: "igdb",
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
      |> MediaAsset.changeset(Map.merge(attrs, %{game_id: game.id, position: position}))
      |> Repo.insert_or_update!()
    end)

    :ok
  end

  defp media_attrs(payload) do
    cover =
      case payload["cover"] do
        %{"image_id" => image_id} ->
          [image_attrs("cover", image_id, "cover_big_2x")]

        _other ->
          []
      end

    screenshots =
      payload
      |> Map.get("screenshots", [])
      |> Enum.take(12)
      |> Enum.map(&image_attrs("screenshot", &1["image_id"], "screenshot_big"))

    videos =
      payload
      |> Map.get("videos", [])
      |> Enum.take(6)
      |> Enum.map(fn video ->
        %{
          kind: "video",
          source: "igdb",
          remote_id: video["video_id"],
          remote_url: "https://www.youtube.com/watch?v=#{video["video_id"]}",
          cache_status: "remote"
        }
      end)

    cover ++ screenshots ++ videos
  end

  defp image_attrs(kind, image_id, size) do
    %{
      kind: kind,
      source: "igdb",
      remote_id: image_id,
      remote_url: "https://images.igdb.com/igdb/image/upload/t_#{size}/#{image_id}.jpg",
      cache_status: "remote"
    }
  end

  defp roles(involvement) do
    []
    |> maybe_role(involvement["developer"], "developer")
    |> maybe_role(involvement["publisher"], "publisher")
  end

  defp maybe_role(roles, true, role), do: [role | roles]
  defp maybe_role(roles, _value, _role), do: roles

  defp link_exact_sources(exact, methods, ingested) do
    Enum.each(exact, fn {source_id, igdb_id} ->
      if game = ingested[igdb_id] do
        method = Map.fetch!(methods, source_id)

        {:ok, :linked} =
          Repo.transact_with_busy_retry(
            fn ->
              source = Repo.get!(GameSource, source_id)

              if source.nsfw and not game.nsfw do
                game |> Game.changeset(%{nsfw: true}) |> Repo.update!()
              end

              source
              |> GameSource.changeset(%{
                game_id: game.id,
                match_method: method
              })
              |> Repo.update!()

              {:ok, :linked}
            end,
            mode: :immediate
          )
      end
    end)

    :ok
  end

  defp erotic_theme?(payload) do
    Enum.any?(payload["themes"] || [], &(&1["id"] == 42 or &1["name"] == "Erotic"))
  end

  defp cache_covers(games, cache_cover, options) do
    Enum.reduce(games, %{cached: 0, failed: 0, failures: []}, fn game, counts ->
      case cache_cover.(game.id, Keyword.get(options, :media_options, [])) do
        {:ok, :no_cover} ->
          counts

        {:ok, _asset} ->
          %{counts | cached: counts.cached + 1}

        {:error, reason} ->
          %{
            counts
            | failed: counts.failed + 1,
              failures:
                add_failure(counts.failures, %{
                  kind: "cover_cache_failed",
                  message:
                    "#{game.title}: cover could not be cached (#{failure_message(reason)})",
                  retryable: true
                })
          }
      end
    end)
  end

  defp pending_remote_cover_games do
    Repo.all(
      from game in Game,
        join: asset in MediaAsset,
        on: asset.game_id == game.id,
        where: asset.kind == "cover" and asset.cache_status == "remote",
        distinct: true
    )
  end

  defp cache_screenshots(options, progress) do
    if Keyword.get(options, :download_screenshots, Media.download_screenshots?()) do
      cache_screenshots = Keyword.get(options, :cache_screenshots, &Media.cache_screenshots/1)

      with :ok <- progress.("screenshots_caching", %{}),
           {:ok, counts} <- cache_screenshots.(Keyword.get(options, :media_options, [])) do
        {:ok,
         %{
           cached: Map.get(counts, :cached, 0),
           failed: Map.get(counts, :failed, 0),
           failures: screenshot_cache_failures(Map.get(counts, :failures, []))
         }}
      else
        {:error, reason} ->
          {:ok,
           %{
             cached: 0,
             failed: 1,
             failures: [
               %{
                 kind: "screenshot_cache_failed",
                 message: "Screenshots could not be cached (#{failure_message(reason)})",
                 retryable: true
               }
             ]
           }}
      end
    else
      {:ok, %{cached: 0, failed: 0, failures: []}}
    end
  end

  defp screenshot_cache_failures(failures) do
    Enum.map(failures, fn failure ->
      asset_label =
        case Map.get(failure, :asset_id) do
          id when is_integer(id) -> "Screenshot #{id}"
          _id -> "A screenshot"
        end

      %{
        kind: "screenshot_cache_failed",
        message:
          "#{asset_label} could not be cached (#{Map.get(failure, :reason, "unknown error")})",
        retryable: true
      }
    end)
  end

  defp add_failure(failures, failure), do: Enum.take(failures ++ [failure], 20)

  defp failure_message(%Iri.Integrations.Error{message: message}), do: message
  defp failure_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_message(_reason), do: "unexpected error"

  defp retryable?(%Iri.Integrations.Error{retryable: retryable?}), do: retryable?
  defp retryable?(_reason), do: true

  defp number(value) when is_number(value), do: value / 1
  defp number(_value), do: nil

  defp unix_date(value) do
    case unix_datetime(value) do
      %DateTime{} = datetime -> DateTime.to_date(datetime)
      nil -> nil
    end
  end

  defp unix_datetime(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> DateTime.truncate(datetime, :second)
      _error -> nil
    end
  end

  defp unix_datetime(_value), do: nil
end
