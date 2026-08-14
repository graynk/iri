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

defmodule Iri.Integrations.Custom do
  @moduledoc "Adds manually owned games by selecting canonical IGDB records."

  import Ecto.Query, warn: false

  alias Iri.Accounts.{Scope, User}
  alias Iri.Integrations
  alias Iri.Integrations.IGDB.{Client, Enricher}
  alias Iri.Integrations.ProviderAccount
  alias Iri.Collections.{Collection, CollectionGame}
  alias Iri.Library.{Access, Game, GameSource, LibraryItem, Title, UserGameState}
  alias Iri.Media
  alias Iri.Params
  alias Iri.Repo
  alias Iri.Security.Redactor

  require Logger

  @max_batch 500

  @doc "Searches IGDB for games a user can add to their private custom library."
  def search(%Scope{user: %User{}} = scope, query, options \\ []) when is_binary(query) do
    if String.length(String.trim(query)) < 2 do
      {:ok, []}
    else
      with {:ok, credentials} <- credentials(options),
           {:ok, games} <-
             client(options).search_games(credentials, query, client_options(options)) do
        {:ok, annotate_ownership(scope, games)}
      end
    end
  end

  @doc "Parses up to 500 numeric IGDB IDs or IGDB game URLs from pasted input."
  def parse_ids(input) when is_binary(input) do
    ids =
      Regex.scan(~r/(?:igdb\.com\/games\/[^\s,]+\/)?(\d+)/i, input, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_integer/1)
      |> Enum.filter(&(&1 > 0))
      |> Enum.uniq()

    cond do
      ids == [] -> {:error, :no_igdb_ids}
      length(ids) > @max_batch -> {:error, :too_many_igdb_ids}
      true -> {:ok, ids}
    end
  end

  @doc "Fetches selected IGDB records and creates private custom-library ownership."
  def add_ids(scope, ids, options \\ [])

  def add_ids(%Scope{user: %User{} = user} = scope, ids, options) when is_list(ids) do
    with true <- length(ids) <= @max_batch,
         {:ok, credentials} <- credentials(options),
         {:ok, payloads} <- fetch_games(ids, credentials, options) do
      results = Enum.map(payloads, &add_payload(scope, user, &1))
      added = Enum.count(results, &match?({:ok, _}, &1))
      already_owned = Enum.count(results, &match?({:already_owned, _}, &1))
      schedule_cover_cache(results, options)

      {:ok,
       %{
         requested: length(ids),
         found: length(payloads),
         added: added,
         already_owned: already_owned,
         failed: length(ids) - added - already_owned
       }}
    else
      false -> {:error, :too_many_igdb_ids}
      error -> error
    end
  end

  def add_ids(_scope, _ids, _options), do: {:error, :unauthorized}

  @doc "Reports whether IGDB results are already accessible or custom-owned by the viewer."
  def ownership_status(%Scope{user: %User{id: user_id}} = scope, igdb_ids)
      when is_list(igdb_ids) do
    ids = igdb_ids |> Enum.filter(&is_integer/1) |> Enum.uniq()
    accessible_account_ids = Access.account_ids(scope)

    rows =
      Repo.all(
        from game in Game,
          join: source in assoc(game, :sources),
          join: item in assoc(source, :library_items),
          join: account in assoc(item, :provider_account),
          where:
            game.igdb_id in ^ids and not item.hidden and
              is_nil(item.removed_at) and account.enabled and
              account.id in subquery(accessible_account_ids),
          select: {game.igdb_id, account.provider, account.owner_user_id}
      )

    statuses =
      Enum.reduce(rows, %{}, fn {igdb_id, provider, owner_user_id}, statuses ->
        Map.update(
          statuses,
          igdb_id,
          %{owned: true, custom_owned: provider == :custom and owner_user_id == user_id},
          fn current ->
            %{
              owned: true,
              custom_owned:
                current.custom_owned or (provider == :custom and owner_user_id == user_id)
            }
          end
        )
      end)

    {:ok, statuses}
  end

  def ownership_status(_scope, _igdb_ids), do: {:error, :unauthorized}

  @doc "Removes the viewer's private custom ownership for one IGDB game."
  def remove_igdb_id(%Scope{user: %User{id: user_id}}, igdb_id)
      when is_integer(igdb_id) and igdb_id > 0 do
    Repo.transact(fn ->
      item_ids =
        Repo.all(
          from item in LibraryItem,
            join: source in assoc(item, :game_source),
            join: game in assoc(source, :game),
            join: account in assoc(item, :provider_account),
            where:
              game.igdb_id == ^igdb_id and account.provider == :custom and
                account.owner_user_id == ^user_id,
            select: item.id
        )

      {removed, _} = Repo.delete_all(from item in LibraryItem, where: item.id in ^item_ids)

      Repo.delete_all(
        from source in GameSource,
          as: :source,
          where:
            source.provider == :igdb and source.external_id == ^to_string(igdb_id) and
              not exists(
                from item in LibraryItem, where: item.game_source_id == parent_as(:source).id
              )
      )

      {:ok, %{removed: removed}}
    end)
  end

  def remove_igdb_id(%Scope{user: %User{}}, _igdb_id), do: {:error, :invalid_igdb_id}
  def remove_igdb_id(_scope, _igdb_id), do: {:error, :unauthorized}

  @doc "Loads a game only when it is privately owned by the viewer's custom library."
  def get_replaceable_game(%Scope{user: %User{id: user_id}}, game_id) do
    case Params.positive_integer(game_id) do
      nil ->
        {:error, :not_found}

      game_id ->
        query =
          from game in Game,
            join: source in assoc(game, :sources),
            join: item in assoc(source, :library_items),
            join: account in assoc(item, :provider_account),
            where:
              game.id == ^game_id and source.provider == :igdb and account.provider == :custom and
                account.owner_user_id == ^user_id and not item.hidden and
                is_nil(item.removed_at),
            limit: 1

        case Repo.one(query) do
          %Game{} = game -> {:ok, game}
          nil -> {:error, :not_found}
        end
    end
  end

  def get_replaceable_game(_scope, _game_id), do: {:error, :unauthorized}

  @doc "Re-points a viewer-owned custom game to a different canonical IGDB record."
  def replace_game(scope, old_game_id, new_igdb_id, options \\ [])

  def replace_game(%Scope{user: %User{} = user} = scope, old_game_id, new_igdb_id, options) do
    with {:ok, old_game} <- get_replaceable_game(scope, old_game_id),
         {:ok, new_igdb_id} <- parse_igdb_id(new_igdb_id),
         true <- old_game.igdb_id != new_igdb_id,
         {:ok, credentials} <- credentials(options),
         {:ok, [payload]} <-
           client(options).games(credentials, [new_igdb_id], client_options(options)),
         {:ok, target_game} <- Enricher.ingest_selected_game(payload),
         {:ok, result} <- replace_custom_ownership(scope, user, old_game, target_game, payload) do
      schedule_cover_cache([{:ok, target_game}], options)
      {:ok, result}
    else
      false -> {:error, :same_game}
      {:ok, []} -> {:error, :game_not_found}
      {:ok, _unexpected} -> {:error, :game_not_found}
      error -> error
    end
  end

  def replace_game(_scope, _old_game_id, _new_igdb_id, _options),
    do: {:error, :unauthorized}

  defp fetch_games(ids, credentials, options) do
    Enum.reduce_while(Enum.chunk_every(ids, 500), {:ok, []}, fn chunk, {:ok, acc} ->
      case client(options).games(credentials, chunk, client_options(options)) do
        {:ok, games} -> {:cont, {:ok, acc ++ games}}
        error -> {:halt, error}
      end
    end)
  end

  defp add_payload(scope, user, %{"id" => _id, "name" => _title} = payload) do
    with {:ok, game} <- Enricher.ingest_selected_game(payload) do
      if Access.game?(scope, game.id) do
        {:already_owned, game}
      else
        with {:ok, account} <- custom_account(user) do
          Repo.transact(fn ->
            with {:ok, _item} <- upsert_custom_ownership(account, game, payload) do
              {:ok, game}
            end
          end)
        end
      end
    end
  end

  defp replace_custom_ownership(scope, user, old_game, target_game, payload) do
    Repo.transact_with_busy_retry(
      fn ->
        with %LibraryItem{} = old_item <- custom_item(user.id, old_game.id),
             {:ok, _target_item} <- maybe_add_custom_item(scope, user, target_game, payload),
             {:ok, _deleted} <- Repo.delete(old_item) do
          old_source_id = old_item.game_source_id

          unless Access.game?(scope, old_game.id) do
            migrate_personalization(user.id, old_game.id, target_game.id)
          end

          cleanup_unused_source(old_source_id)
          {:ok, %{game: target_game}}
        else
          nil -> {:error, :not_found}
          error -> error
        end
      end,
      mode: :immediate
    )
  end

  defp maybe_add_custom_item(scope, user, target_game, payload) do
    if Access.game?(scope, target_game.id) do
      {:ok, :already_owned}
    else
      with {:ok, account} <- custom_account(user) do
        upsert_custom_ownership(account, target_game, payload)
      end
    end
  end

  defp upsert_custom_ownership(account, game, %{"id" => id, "name" => title} = payload) do
    source =
      Repo.get_by(GameSource, provider: :igdb, external_id: to_string(id)) || %GameSource{}

    with {:ok, source} <-
           source
           |> GameSource.changeset(%{
             provider: :igdb,
             external_id: to_string(id),
             game_id: game.id,
             source_title: title,
             normalized_source_title: Title.normalize(title),
             source_url: "https://www.igdb.com/games/#{payload["slug"] || game.slug}",
             metadata_snapshot: %{"igdb_id" => id, "ownership_provider" => "custom"},
             match_method: "manual_igdb",
             manual_lock: true,
             catalog_kind: "game"
           })
           |> Repo.insert_or_update() do
      item =
        Repo.get_by(LibraryItem, provider_account_id: account.id, game_source_id: source.id) ||
          %LibraryItem{}

      item
      |> LibraryItem.changeset(%{
        provider_account_id: account.id,
        game_source_id: source.id,
        relationship: :manual,
        hidden: false,
        removed_at: nil
      })
      |> Repo.insert_or_update()
    end
  end

  defp custom_item(user_id, game_id) do
    Repo.one(
      from item in LibraryItem,
        join: source in assoc(item, :game_source),
        join: account in assoc(item, :provider_account),
        where:
          source.game_id == ^game_id and source.provider == :igdb and
            account.provider == :custom and account.owner_user_id == ^user_id and
            not item.hidden and is_nil(item.removed_at),
        limit: 1
    )
  end

  defp migrate_personalization(user_id, old_game_id, target_game_id) do
    migrate_user_state(user_id, old_game_id, target_game_id)
    migrate_collection_entries(user_id, old_game_id, target_game_id)
  end

  defp migrate_user_state(user_id, old_game_id, target_game_id) do
    old_state = Repo.get_by(UserGameState, user_id: user_id, game_id: old_game_id)
    target_state = Repo.get_by(UserGameState, user_id: user_id, game_id: target_game_id)

    case {old_state, target_state} do
      {nil, _target} ->
        :ok

      {%UserGameState{} = old, nil} ->
        old |> Ecto.Changeset.change(game_id: target_game_id) |> Repo.update!()

      {%UserGameState{} = old, %UserGameState{} = target} ->
        target
        |> UserGameState.changeset(%{
          state: target.state || old.state,
          notes: target.notes || old.notes,
          rating: target.rating || old.rating
        })
        |> Repo.update!()

        Repo.delete!(old)
    end
  end

  defp migrate_collection_entries(user_id, old_game_id, target_game_id) do
    entries =
      Repo.all(
        from entry in CollectionGame,
          join: collection in assoc(entry, :collection),
          where: collection.user_id == ^user_id and entry.game_id == ^old_game_id
      )

    now = DateTime.utc_now(:second)

    Enum.each(entries, fn entry ->
      case Repo.get_by(CollectionGame,
             collection_id: entry.collection_id,
             game_id: target_game_id
           ) do
        nil ->
          entry |> Ecto.Changeset.change(game_id: target_game_id) |> Repo.update!()

        target_entry ->
          if is_nil(target_entry.comment) and not is_nil(entry.comment) do
            target_entry
            |> CollectionGame.comment_changeset(%{comment: entry.comment})
            |> Repo.update!()
          end

          Repo.delete!(entry)
      end

      Repo.update_all(
        from(collection in Collection, where: collection.id == ^entry.collection_id),
        set: [updated_at: now]
      )
    end)
  end

  defp cleanup_unused_source(source_id) do
    unless Repo.exists?(from item in LibraryItem, where: item.game_source_id == ^source_id) do
      Repo.delete_all(from source in GameSource, where: source.id == ^source_id)
    end
  end

  defp parse_igdb_id(value) do
    case Params.positive_integer(value) do
      nil -> {:error, :invalid_igdb_id}
      id -> {:ok, id}
    end
  end

  defp annotate_ownership(scope, games) do
    ids = Enum.map(games, & &1["id"])
    {:ok, statuses} = ownership_status(scope, ids)

    Enum.map(games, fn game ->
      status = Map.get(statuses, game["id"], %{owned: false, custom_owned: false})

      game
      |> Map.put("owned", status.owned)
      |> Map.put("custom_owned", status.custom_owned)
    end)
  end

  defp custom_account(user) do
    external_id = "user:#{user.id}"

    account =
      Repo.get_by(ProviderAccount, provider: :custom, external_user_id: external_id) ||
        %ProviderAccount{}

    account
    |> ProviderAccount.changeset(%{
      provider: :custom,
      external_user_id: external_id,
      display_name: "Custom games",
      sync_status: "ready"
    })
    |> Ecto.Changeset.put_change(:owner_user_id, user.id)
    |> Repo.insert_or_update()
  end

  defp credentials(options),
    do: Integrations.igdb_credentials_for_sync(client(options), client_options(options))

  defp client(options),
    do: Keyword.get(options, :client, Application.get_env(:iri, :igdb_client, Client))

  defp client_options(options), do: Keyword.get(options, :client_options, [])

  defp schedule_cover_cache(results, options) do
    game_ids =
      results
      |> Enum.flat_map(fn
        {:ok, game} -> [game.id]
        {:already_owned, game} -> [game.id]
        _result -> []
      end)
      |> Enum.uniq()

    cache_cover = Keyword.get(options, :cache_cover)
    media_options = Keyword.get(options, :media_options, [])

    cond do
      is_function(cache_cover, 2) ->
        Enum.each(game_ids, &cache_cover.(&1, media_options))
        :ok

      game_ids != [] and Application.get_env(:iri, :cache_custom_game_covers, true) ->
        _result =
          Task.Supervisor.start_child(Iri.Sync.TaskSupervisor, fn ->
            Enum.each(game_ids, &cache_cover_safely(&1, media_options))
          end)

        :ok

      true ->
        :ok
    end
  end

  # Cache each cover independently: a single failure must neither abort the rest
  # nor vanish silently. Anything left as a "remote" cover is still picked up by
  # the next library enrichment pass.
  defp cache_cover_safely(game_id, media_options) do
    case Media.cache_cover(game_id, media_options) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Could not cache custom game cover for game #{game_id}: #{Redactor.redact_inspect(reason)}"
        )
    end
  rescue
    exception ->
      Logger.warning(
        "Custom game cover caching crashed for game #{game_id}: #{Redactor.exception_message(exception)}"
      )
  end
end
