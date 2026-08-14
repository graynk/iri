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

defmodule Iri.Matches do
  @moduledoc "Administrator review workflow for unresolved canonical game matches."

  import Ecto.Query, warn: false

  alias Iri.Accounts.Scope
  alias Iri.Integrations
  alias Iri.Integrations.IGDB.{Client, Enricher, Matcher, TitleSearch}
  alias Iri.Integrations.VNDB.Client, as: VNDBClient
  alias Iri.Integrations.VNDB.Enricher, as: VNDBEnricher
  alias Iri.Library.{GameSource, MatchCandidate, Title}
  alias Iri.Matches.Decisions
  alias Iri.Media
  alias Iri.Params
  alias Iri.Repo

  @review_providers [:steam, :gog, :epic, :psn, :xbox]
  @ai_ready_match_methods ~w(ambiguous unmatched)

  @doc "Lists unresolved store sources for administrator matching, optionally focused on one source."
  def list_queue(%Scope{} = scope, options \\ []) do
    with :ok <- authorize_admin(scope) do
      # A source explicitly opened via "Fix match" is shown even when its
      # provider is outside the automatic review set (e.g. a custom game).
      focus_id = Params.positive_integer(Keyword.get(options, :focus_source_id)) || 0

      query =
        from source in GameSource,
          join: item in assoc(source, :library_items),
          join: account in assoc(item, :provider_account),
          where:
            (source.provider in ^@review_providers or source.id == ^focus_id) and
              not source.manual_lock and
              is_nil(source.game_id) and not item.hidden and
              is_nil(item.removed_at) and account.enabled and
              (is_nil(source.catalog_kind) or source.catalog_kind in ["game", "unknown"]),
          distinct: true,
          order_by: [asc: source.normalized_source_title, asc: source.id],
          preload: [
            match_candidates:
              ^from(candidate in MatchCandidate,
                order_by: [desc: candidate.score, asc: candidate.title]
              )
          ]

      query = prioritize_source(query, Keyword.get(options, :focus_source_id))

      query = filter_source_ids(query, Keyword.get(options, :source_ids))

      query =
        if Keyword.get(options, :ai_ready, false) do
          from source in query, where: source.match_method in ^@ai_ready_match_methods
        else
          query
        end

      query =
        case Keyword.get(options, :limit, 200) do
          :all -> query
          limit when is_integer(limit) and limit > 0 -> from(source in query, limit: ^limit)
        end

      {:ok, Repo.all(query)}
    end
  end

  defp filter_source_ids(query, source_ids) when is_list(source_ids) do
    from source in query, where: source.id in ^source_ids
  end

  defp filter_source_ids(query, _source_ids), do: query

  @doc "Counts unresolved sources visible in the administrator match queue."
  def count_queue(%Scope{} = scope) do
    with :ok <- authorize_admin(scope) do
      query =
        from source in GameSource,
          join: item in assoc(source, :library_items),
          join: account in assoc(item, :provider_account),
          where:
            source.provider in ^@review_providers and not source.manual_lock and
              is_nil(source.game_id) and not item.hidden and
              is_nil(item.removed_at) and account.enabled and
              (is_nil(source.catalog_kind) or source.catalog_kind in ["game", "unknown"]),
          select: count(source.id, :distinct)

      {:ok, Repo.one(query)}
    end
  end

  @doc "Refreshes deterministic IGDB candidates for an unresolved source."
  def find_candidates(%Scope{} = scope, source_id, options \\ []) do
    with :ok <- authorize_admin(scope),
         %GameSource{} = source <- Repo.get(GameSource, source_id),
         false <- source.manual_lock,
         {:ok, candidates} <- search(source, source.source_title, true, options) do
      persist_candidates(source, candidates)
      {:ok, Repo.preload(source, :match_candidates, force: true)}
    else
      nil -> {:error, :not_found}
      true -> {:error, :manual_decision_locked}
      error -> error
    end
  end

  @doc "Searches IGDB with an administrator-supplied query and stores the candidates for review."
  def search_candidates(%Scope{} = scope, source_id, query, options \\ []) do
    query = if is_binary(query), do: String.trim(query), else: ""

    with :ok <- authorize_admin(scope),
         :ok <- if(query == "", do: {:error, :invalid_search}, else: :ok),
         %GameSource{} = source <- Repo.get(GameSource, source_id),
         false <- source.manual_lock,
         {:ok, candidates} <- search(source, query, false, options) do
      persist_candidates(source, candidates)
      {:ok, Repo.preload(source, :match_candidates, force: true)}
    else
      nil -> {:error, :not_found}
      true -> {:error, :manual_decision_locked}
      error -> error
    end
  end

  defp search(source, query, include_stored?, options) do
    with client =
           Keyword.get(options, :client, Application.get_env(:iri, :igdb_client, Client)),
         client_options = Keyword.get(options, :client_options, []),
         {:ok, credentials} <- Integrations.igdb_credentials_for_sync(client, client_options),
         {:ok, candidates} <-
           TitleSearch.search(
             client,
             credentials,
             query,
             client_options
           ) do
      if include_stored? do
        include_stored_candidates(source, candidates, credentials, client, client_options)
      else
        {:ok, candidates}
      end
    end
  end

  @doc "Applies one stored IGDB candidate as a locked manual match."
  def apply_candidate(%Scope{} = scope, source_id, igdb_id, options \\ []) do
    with :ok <- authorize_admin(scope),
         {:ok, igdb_id} <- parse_id(igdb_id),
         %GameSource{} = source <- Repo.get(GameSource, source_id),
         %MatchCandidate{} <-
           Repo.get_by(MatchCandidate, game_source_id: source.id, igdb_id: igdb_id),
         client =
           Keyword.get(options, :client, Application.get_env(:iri, :igdb_client, Client)),
         client_options = Keyword.get(options, :client_options, []),
         {:ok, credentials} <- Integrations.igdb_credentials_for_sync(client, client_options),
         {:ok, [payload]} <- client.games(credentials, [igdb_id], client_options),
         {:ok, game} <- Enricher.ingest_selected_game(payload),
         {:ok, source} <-
           apply_decision(
             source,
             %{
               action: "match",
               game_id: game.id,
               method: "manual",
               confidence: 1.0,
               selected_catalog: "igdb",
               selected_external_id: igdb_id,
               reason: "Administrator selected an IGDB candidate"
             },
             admin_actor(scope)
           ) do
      cache_cover = Keyword.get(options, :cache_cover, &Media.cache_cover/2)
      _result = cache_cover.(game.id, Keyword.get(options, :media_options, []))
      {:ok, source}
    else
      nil -> {:error, :not_found}
      {:ok, []} -> {:error, :candidate_not_found}
      error -> error
    end
  end

  @doc "Fetches and applies an administrator-supplied IGDB ID as a locked manual match."
  def apply_igdb_id(%Scope{} = scope, source_id, igdb_id, options \\ []) do
    with :ok <- authorize_admin(scope),
         {:ok, igdb_id} <- parse_id(igdb_id),
         %GameSource{manual_lock: false} = source <- Repo.get(GameSource, source_id),
         client =
           Keyword.get(options, :client, Application.get_env(:iri, :igdb_client, Client)),
         client_options = Keyword.get(options, :client_options, []),
         {:ok, credentials} <- Integrations.igdb_credentials_for_sync(client, client_options),
         {:ok, [payload]} <- client.games(credentials, [igdb_id], client_options),
         {:ok, game} <- Enricher.ingest_selected_game(payload),
         {:ok, source} <-
           apply_decision(
             source,
             %{
               action: "match",
               game_id: game.id,
               method: "manual_id",
               confidence: 1.0,
               selected_catalog: "igdb",
               selected_external_id: igdb_id,
               reason: "Administrator entered an exact IGDB ID"
             },
             admin_actor(scope)
           ) do
      cache_cover = Keyword.get(options, :cache_cover, &Media.cache_cover/2)
      _result = cache_cover.(game.id, Keyword.get(options, :media_options, []))
      {:ok, source}
    else
      nil -> {:error, :not_found}
      %GameSource{} -> {:error, :manual_decision_locked}
      {:ok, []} -> {:error, :candidate_not_found}
      {:ok, _unexpected_results} -> {:error, :candidate_not_found}
      error -> error
    end
  end

  @doc "Searches VNDB for an administrator to inspect without applying a title-only guess."
  def search_vndb_candidates(%Scope{} = scope, source_id, query, options \\ []) do
    query = Title.for_provider_search(query)

    with :ok <- authorize_admin(scope),
         :ok <- if(query == "", do: {:error, :invalid_search}, else: :ok),
         %GameSource{manual_lock: false} <- Repo.get(GameSource, source_id),
         client =
           Keyword.get(options, :client, Application.get_env(:iri, :vndb_client, VNDBClient)),
         {:ok, candidates} <-
           client.search_games(query, Keyword.get(options, :client_options, [])) do
      {:ok, candidates}
    else
      nil -> {:error, :not_found}
      %GameSource{} -> {:error, :manual_decision_locked}
      error -> error
    end
  end

  @doc "Fetches and applies a VNDB record as a locked manual match."
  def apply_vndb_id(%Scope{} = scope, source_id, vndb_id, options \\ []) do
    with :ok <- authorize_admin(scope),
         {:ok, vndb_id} <- parse_vndb_id(vndb_id),
         %GameSource{manual_lock: false} = source <- Repo.get(GameSource, source_id),
         client =
           Keyword.get(options, :client, Application.get_env(:iri, :vndb_client, VNDBClient)),
         {:ok, [payload]} <-
           client.games([vndb_id], Keyword.get(options, :client_options, [])),
         {:ok, game} <- VNDBEnricher.ingest_game(payload, options),
         {:ok, source} <-
           apply_decision(
             source,
             %{
               action: "match",
               game_id: game.id,
               method: "manual_vndb",
               confidence: 1.0,
               selected_catalog: "vndb",
               selected_external_id: vndb_id,
               reason: "Administrator selected a VNDB candidate"
             },
             admin_actor(scope)
           ) do
      {:ok, source}
    else
      nil -> {:error, :not_found}
      %GameSource{} -> {:error, :manual_decision_locked}
      {:ok, []} -> {:error, :candidate_not_found}
      {:ok, _unexpected_results} -> {:error, :candidate_not_found}
      error -> error
    end
  end

  @doc "Keeps a source as a visible store-only game and removes it from matching review."
  def ignore_source(%Scope{} = scope, source_id) do
    with :ok <- authorize_admin(scope),
         %GameSource{} = source <- Repo.get(GameSource, source_id) do
      apply_decision(
        source,
        %{
          action: "keep_store_only",
          method: "ignored",
          confidence: nil,
          selected_catalog: "store",
          selected_external_id: source.external_id,
          reason: "Administrator kept the source without catalog metadata"
        },
        admin_actor(scope)
      )
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Marks a source as non-game content so it is hidden from imported libraries."
  def reject_source(%Scope{} = scope, source_id) do
    with :ok <- authorize_admin(scope),
         %GameSource{manual_lock: false} = source <- Repo.get(GameSource, source_id) do
      apply_decision(
        source,
        %{
          action: "reject",
          method: "rejected",
          confidence: nil,
          reason: "Administrator rejected this source as a non-game"
        },
        admin_actor(scope)
      )
    else
      nil -> {:error, :not_found}
      %GameSource{} -> {:error, :manual_decision_locked}
      error -> error
    end
  end

  defp persist_candidates(source, candidates) do
    now = DateTime.utc_now(:second)

    rows =
      source.source_title
      |> Matcher.rank(candidates, provider: source.provider)
      |> Enum.map(fn candidate ->
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

    Repo.delete_all(
      from candidate in MatchCandidate, where: candidate.game_source_id == ^source.id
    )

    Repo.insert_all(MatchCandidate, rows, on_conflict: :nothing)
    mark_review_state(source, if(rows == [], do: "unmatched", else: "ambiguous"))
  end

  defp include_stored_candidates(source, search_results, credentials, client, client_options) do
    stored_ids =
      Repo.all(
        from candidate in MatchCandidate,
          where: candidate.game_source_id == ^source.id,
          select: candidate.igdb_id
      )

    case stored_ids do
      [] ->
        {:ok, search_results}

      ids ->
        with {:ok, stored_games} <- client.games(credentials, ids, client_options) do
          {:ok, Enum.uniq_by(stored_games ++ search_results, & &1["id"])}
        end
    end
  end

  defp mark_review_state(source, method) do
    source
    |> GameSource.changeset(%{match_method: method})
    |> Repo.update!()
  end

  @doc "Lists the administrator audit history of manual and AI matching decisions."
  def list_history(%Scope{} = scope, limit \\ 5_000) do
    with :ok <- authorize_admin(scope), do: {:ok, Decisions.list_history(limit)}
  end

  @doc "Lists resolved sources that can be reopened for a corrected decision."
  def list_resolved_sources(%Scope{} = scope, limit \\ 5_000) do
    with :ok <- authorize_admin(scope) do
      {:ok,
       Repo.all(
         from source in GameSource,
           join: item in assoc(source, :library_items),
           join: account in assoc(item, :provider_account),
           where:
             source.provider in ^@review_providers and source.manual_lock and
               not item.hidden and is_nil(item.removed_at) and account.enabled,
           distinct: true,
           order_by: [asc: source.normalized_source_title, asc: source.id],
           limit: ^limit,
           preload: [:game]
       )}
    end
  end

  @doc "Returns a resolved source to the matching queue."
  def reopen_source(%Scope{} = scope, source_id) do
    with :ok <- authorize_admin(scope),
         %GameSource{manual_lock: true} = source <- Repo.get(GameSource, source_id),
         {:ok, {source, _decision}} <- Decisions.reopen(source, admin_actor(scope)) do
      {:ok, source}
    else
      nil -> {:error, :not_found}
      %GameSource{} -> {:error, :not_locked}
      error -> error
    end
  end

  @doc """
  Reopens every owned source of a game for admin match review.

  Works for any provider, including custom (IGDB) games, so a mismatched game
  can be re-pointed from its detail page. Returns a source id to focus the
  review page on.
  """
  def reopen_game_for_review(%Scope{} = scope, game_id) do
    with :ok <- authorize_admin(scope),
         game_id when is_integer(game_id) and game_id > 0 <- Params.positive_integer(game_id),
         [_ | _] = sources <- owned_game_sources(game_id) do
      Enum.each(sources, fn source ->
        if not is_nil(source.game_id) or source.manual_lock do
          Decisions.reopen(source, admin_actor(scope))
        end
      end)

      {:ok, focus_source_id(sources)}
    else
      [] -> {:error, :not_found}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp owned_game_sources(game_id) do
    Repo.all(
      from source in GameSource,
        join: item in assoc(source, :library_items),
        join: account in assoc(item, :provider_account),
        where:
          source.game_id == ^game_id and not item.hidden and
            is_nil(item.removed_at) and account.enabled,
        distinct: true,
        order_by: [asc: source.id]
    )
  end

  # Prefer an automatically reviewable store source for focus; fall back to the
  # first source (e.g. a custom one), which the queue includes when focused.
  defp focus_source_id(sources) do
    store = Enum.find(sources, &(&1.provider in @review_providers))
    (store || hd(sources)).id
  end

  @doc "Returns an eligible source to the matching queue without discarding its source record."
  def open_source_for_review(%Scope{} = scope, source_id) do
    with :ok <- authorize_admin(scope),
         source_id when is_integer(source_id) and source_id > 0 <-
           Params.positive_integer(source_id),
         %GameSource{} = source <- reviewable_owned_source(source_id) do
      cond do
        not is_nil(source.game_id) or source.manual_lock ->
          case Decisions.reopen(source, admin_actor(scope)) do
            {:ok, {source, _decision}} -> {:ok, source}
            error -> error
          end

        true ->
          {:ok, source}
      end
    else
      _missing -> {:error, :not_found}
    end
  end

  defp apply_decision(source, attrs, actor) do
    case Decisions.apply(source, attrs, actor) do
      {:ok, {source, _decision}} -> {:ok, source}
      error -> error
    end
  end

  defp authorize_admin(%Scope{} = scope) do
    if Scope.admin?(scope), do: :ok, else: {:error, :unauthorized}
  end

  defp admin_actor(%Scope{user: user}), do: %{type: "admin", user_id: user.id}

  defp reviewable_owned_source(source_id) do
    Repo.one(
      from source in GameSource,
        join: item in assoc(source, :library_items),
        join: account in assoc(item, :provider_account),
        where:
          source.id == ^source_id and source.provider in ^@review_providers and
            not item.hidden and is_nil(item.removed_at) and account.enabled,
        distinct: true,
        limit: 1
    )
  end

  defp prioritize_source(query, value) do
    case Params.positive_integer(value) do
      nil ->
        query

      source_id ->
        query
        |> exclude(:order_by)
        |> order_by(
          [source],
          asc: fragment("CASE WHEN ? = ? THEN 0 ELSE 1 END", source.id, ^source_id),
          asc: source.normalized_source_title,
          asc: source.id
        )
    end
  end

  defp parse_id(value) do
    case Params.positive_integer(value) do
      nil -> {:error, :invalid_id}
      id -> {:ok, id}
    end
  end

  defp parse_vndb_id("v" <> digits = id) do
    case Integer.parse(digits) do
      {number, ""} when number > 0 -> {:ok, id}
      _error -> {:error, :invalid_id}
    end
  end

  defp parse_vndb_id(value) when is_integer(value) and value > 0, do: {:ok, "v#{value}"}

  defp parse_vndb_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, "v#{number}"}
      _error -> {:error, :invalid_id}
    end
  end

  defp parse_vndb_id(_value), do: {:error, :invalid_id}
end
