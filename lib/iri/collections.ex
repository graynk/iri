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

defmodule Iri.Collections do
  @moduledoc "Scoped personal collections and read-only share capabilities."

  import Ecto.Query, warn: false

  alias Iri.Accounts.Scope
  alias Iri.Accounts.User
  alias Iri.Collections.{Collection, CollectionGame, Ordering}
  alias Iri.InstancePolicy
  alias Iri.Library.{Access, Game, GameSource, LibraryItem, MediaAsset, Playtime}
  alias Iri.Library.{StoreLink, Title, UserGameState}
  alias Iri.Media.Policy
  alias Iri.Params
  alias Iri.Repo

  @share_salt "collection sharing"
  @search_limit 40
  @sort_keys ~w(custom title release_date igdb_rating my_rating)
  @sort_directions ~w(asc desc)
  @collection_page_size 100

  @doc "Lists the signed-in user's collections with accessible entry counts and cover IDs."
  def list_collections(%Scope{user: user} = scope) when not is_nil(user) do
    collections =
      Repo.all(
        from collection in Collection,
          where: collection.user_id == ^user.id,
          order_by: [desc: collection.updated_at, asc: collection.name, asc: collection.id]
      )

    collection_ids = Enum.map(collections, & &1.id)
    counts = collection_game_counts(scope, collection_ids)
    covers = collection_cover_ids(scope, collection_ids)

    Enum.map(collections, fn collection ->
      %{
        collection: collection,
        accessible_game_count: Map.get(counts, collection.id, 0),
        cover_ids: Map.get(covers, collection.id, [])
      }
    end)
  end

  def list_collections(_scope), do: []

  @doc "Lists other users' shared collections when the instance is in Family mode."
  def list_family_public_collections(%Scope{user: user}) when not is_nil(user) do
    if InstancePolicy.family?() do
      collections =
        Repo.all(
          from collection in Collection,
            join: owner in assoc(collection, :user),
            where: collection.user_id != ^user.id and collection.sharing_enabled,
            order_by: [
              desc: collection.updated_at,
              asc: owner.username,
              asc: collection.name,
              asc: collection.id
            ],
            preload: [user: owner]
        )

      {counts, covers} =
        collections
        |> Enum.group_by(& &1.user_id)
        |> Enum.reduce({%{}, %{}}, fn {_owner_id, owner_collections}, {all_counts, all_covers} ->
          owner_scope = Scope.for_user(hd(owner_collections).user)
          collection_ids = Enum.map(owner_collections, & &1.id)

          {
            Map.merge(all_counts, collection_game_counts(owner_scope, collection_ids)),
            Map.merge(all_covers, collection_cover_ids(owner_scope, collection_ids))
          }
        end)

      Enum.map(collections, fn collection ->
        %{
          collection: collection,
          owner_name: collection.user.username,
          accessible_game_count: Map.get(counts, collection.id, 0),
          cover_ids: Map.get(covers, collection.id, []),
          share_token: sign_share_token(collection)
        }
      end)
    else
      []
    end
  end

  def list_family_public_collections(_scope), do: []

  @doc "Lists the signed-in user's collections and whether an accessible game belongs to each."
  def game_collection_memberships(%Scope{user: user} = scope, game_id)
      when not is_nil(user) do
    with game_id when not is_nil(game_id) <- Params.positive_integer(game_id),
         true <- Access.game?(scope, game_id) do
      memberships =
        Repo.all(
          from collection in Collection,
            left_join: entry in CollectionGame,
            on: entry.collection_id == collection.id and entry.game_id == ^game_id,
            where: collection.user_id == ^user.id,
            order_by: [asc: collection.name, asc: collection.id],
            select: %{
              id: collection.id,
              name: collection.name,
              member?: not is_nil(entry.id)
            }
        )

      {:ok, memberships}
    else
      _missing -> {:error, :not_found}
    end
  end

  def game_collection_memberships(_scope, _game_id), do: {:error, :unauthorized}

  @doc "Replaces an accessible game's membership across the signed-in user's collections."
  def set_game_collections(%Scope{user: user} = scope, game_id, collection_ids)
      when not is_nil(user) do
    with game_id when not is_nil(game_id) <- Params.positive_integer(game_id),
         true <- Access.game?(scope, game_id),
         {:ok, selected_ids} <- normalize_ids(collection_ids) do
      Repo.transaction(fn ->
        owned_ids =
          Repo.all(
            from collection in Collection,
              where: collection.user_id == ^user.id,
              select: collection.id,
              order_by: collection.id
          )

        if not Enum.all?(selected_ids, &(&1 in owned_ids)), do: Repo.rollback(:not_found)

        existing_ids =
          Repo.all(
            from entry in CollectionGame,
              where: entry.game_id == ^game_id and entry.collection_id in ^owned_ids,
              select: entry.collection_id,
              order_by: entry.collection_id
          )

        added_ids = selected_ids -- existing_ids
        removed_ids = existing_ids -- selected_ids
        now = DateTime.utc_now(:second)

        if removed_ids != [] do
          Repo.delete_all(
            from entry in CollectionGame,
              where: entry.game_id == ^game_id and entry.collection_id in ^removed_ids
          )

          Enum.each(removed_ids, &Ordering.normalize_positions/1)
        end

        rows =
          Enum.map(added_ids, fn collection_id ->
            %{
              collection_id: collection_id,
              game_id: game_id,
              position: Ordering.next_position(collection_id),
              inserted_at: now,
              updated_at: now
            }
          end)

        {added_count, _rows} = Repo.insert_all(CollectionGame, rows, on_conflict: :nothing)
        changed_ids = Enum.uniq(added_ids ++ removed_ids)
        Enum.each(changed_ids, &Ordering.touch(&1, now))

        %{added: added_count, removed: length(removed_ids)}
      end)
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
      _missing -> {:error, :not_found}
    end
  end

  def set_game_collections(_scope, _game_id, _collection_ids), do: {:error, :unauthorized}

  def get_collection(%Scope{user: user}, collection_id) when not is_nil(user) do
    case Params.positive_integer(collection_id) do
      nil -> {:error, :not_found}
      id -> owned_collection(user.id, id)
    end
  end

  def get_collection(_scope, _collection_id), do: {:error, :unauthorized}

  @doc "Returns a changeset for a collection owned by the supplied scope."
  def change_collection(scope, collection, attrs \\ %{})

  def change_collection(%Scope{user: user}, %Collection{} = collection, attrs)
      when not is_nil(user) and (is_nil(collection.user_id) or collection.user_id == user.id) do
    Collection.changeset(collection, attrs)
  end

  def change_collection(_scope, %Collection{} = collection, attrs),
    do: Collection.changeset(collection, attrs)

  @doc "Creates a private collection for the signed-in user."
  def create_collection(%Scope{user: user}, attrs) when not is_nil(user) do
    %Collection{user_id: user.id}
    |> Collection.changeset(attrs)
    |> Repo.insert()
  end

  def create_collection(_scope, _attrs), do: {:error, :unauthorized}

  @doc "Updates a collection owned by the signed-in user."
  def update_collection(%Scope{user: user}, collection_id, attrs) when not is_nil(user) do
    with {:ok, collection} <- owned_collection(user.id, collection_id) do
      collection
      |> Collection.changeset(attrs)
      |> Repo.update()
    end
  end

  def update_collection(_scope, _collection_id, _attrs), do: {:error, :unauthorized}

  @doc "Deletes a collection owned by the signed-in user and its entries."
  def delete_collection(%Scope{user: user}, collection_id) when not is_nil(user) do
    Repo.transaction(fn ->
      collection = owned_collection_or_rollback(user.id, collection_id)
      Repo.delete!(collection)
    end)
  end

  def delete_collection(_scope, _collection_id), do: {:error, :unauthorized}

  @doc "Loads all accessible entries in an owned collection using its requested presentation order."
  def list_collection_games(%Scope{user: user} = scope, collection_id)
      when not is_nil(user) do
    case list_collection_games(scope, collection_id, "custom", "asc") do
      {:ok, collection, entries, _sort, _direction} -> {:ok, collection, entries}
      error -> error
    end
  end

  def list_collection_games(_scope, _collection_id), do: {:error, :unauthorized}

  def list_collection_games(%Scope{user: user} = scope, collection_id, requested_sort)
      when not is_nil(user) do
    case list_collection_games(scope, collection_id, requested_sort, nil) do
      {:ok, collection, entries, sort, _direction} -> {:ok, collection, entries, sort}
      error -> error
    end
  end

  def list_collection_games(_scope, _collection_id, _requested_sort),
    do: {:error, :unauthorized}

  def list_collection_games(
        %Scope{user: user} = scope,
        collection_id,
        requested_sort,
        requested_direction
      )
      when not is_nil(user) do
    with {:ok, view} <-
           owner_collection_view(user.id, collection_id, requested_sort, requested_direction) do
      {:ok, view.collection,
       collection_entries(scope, view.collection, user.id, view.sort, view.sort_direction),
       view.sort, view.sort_direction}
    end
  end

  def list_collection_games(_scope, _collection_id, _requested_sort, _requested_direction),
    do: {:error, :unauthorized}

  @doc "Loads one cursor-paginated page of accessible collection entries."
  def list_collection_games_page(
        %Scope{user: user} = scope,
        collection_id,
        requested_sort,
        requested_direction,
        cursor
      )
      when not is_nil(user) do
    with {:ok, offset} <- page_offset(cursor),
         {:ok, view} <-
           owner_collection_view(user.id, collection_id, requested_sort, requested_direction) do
      {entries, next_cursor} =
        collection_entries_page(
          scope,
          view.collection,
          user.id,
          view.sort,
          view.sort_direction,
          offset
        )

      {:ok,
       %{
         collection: view.collection,
         entries: entries,
         sort: view.sort,
         sort_direction: view.sort_direction,
         next_cursor: next_cursor,
         total_count: collection_entry_count(scope, view.collection.id)
       }}
    end
  end

  def list_collection_games_page(
        _scope,
        _collection_id,
        _requested_sort,
        _requested_direction,
        _cursor
      ),
      do: {:error, :unauthorized}

  @doc "Searches accessible games that can be added to a collection owned by the viewer."
  def search_addable_games(%Scope{user: user} = scope, collection_id, query)
      when not is_nil(user) do
    with {:ok, collection} <- owned_collection(user.id, collection_id) do
      {:ok, search_games(scope, collection, query)}
    end
  end

  def search_addable_games(_scope, _collection_id, _query), do: {:error, :unauthorized}

  @doc "Adds accessible games to an owned collection at the end of its custom order."
  def add_games(%Scope{user: user} = scope, collection_id, game_ids) when not is_nil(user) do
    with {:ok, game_ids} <- normalize_ids(game_ids) do
      Repo.transaction(fn ->
        collection = owned_collection_or_rollback(user.id, collection_id)

        games =
          Repo.all(
            from game in Game,
              where: game.id in ^game_ids and game.id in subquery(Access.game_ids(scope)),
              order_by: [asc: game.normalized_title, asc: game.id],
              select: %{id: game.id, normalized_title: game.normalized_title}
          )

        if Enum.sort(Enum.map(games, & &1.id)) != game_ids, do: Repo.rollback(:not_found)

        existing_ids =
          Repo.all(
            from entry in CollectionGame,
              where: entry.collection_id == ^collection.id and entry.game_id in ^game_ids,
              select: entry.game_id
          )
          |> MapSet.new()

        new_games = Enum.reject(games, &MapSet.member?(existing_ids, &1.id))
        start_position = Ordering.next_position(collection.id)
        now = DateTime.utc_now(:second)

        rows =
          new_games
          |> Enum.with_index(start_position)
          |> Enum.map(fn {game, position} ->
            %{
              collection_id: collection.id,
              game_id: game.id,
              position: position,
              inserted_at: now,
              updated_at: now
            }
          end)

        {inserted, _rows} = Repo.insert_all(CollectionGame, rows, on_conflict: :nothing)
        if inserted > 0, do: Ordering.touch(collection.id, now)
        inserted
      end)
    end
  end

  def add_games(_scope, _collection_id, _game_ids), do: {:error, :unauthorized}

  @doc "Removes one game from an owned collection and normalizes the remaining positions."
  def remove_game(%Scope{user: user}, collection_id, game_id) when not is_nil(user) do
    Repo.transaction(fn ->
      collection = owned_collection_or_rollback(user.id, collection_id)
      game_id = Params.positive_integer(game_id) || Repo.rollback(:not_found)

      case Repo.get_by(CollectionGame, collection_id: collection.id, game_id: game_id) do
        nil -> Repo.rollback(:not_found)
        entry -> Repo.delete!(entry)
      end

      Ordering.normalize_positions(collection.id)
      Ordering.touch(collection.id, DateTime.utc_now(:second))
      :ok
    end)
  end

  def remove_game(_scope, _collection_id, _game_id), do: {:error, :unauthorized}

  @doc "Updates the private per-entry comment for a game in an owned collection."
  def update_entry_comment(%Scope{user: user}, collection_id, game_id, comment)
      when not is_nil(user) do
    Repo.transaction(fn ->
      collection = owned_collection_or_rollback(user.id, collection_id)
      game_id = Params.positive_integer(game_id) || Repo.rollback(:not_found)

      entry =
        Repo.get_by(CollectionGame, collection_id: collection.id, game_id: game_id) ||
          Repo.rollback(:not_found)

      case entry
           |> CollectionGame.comment_changeset(%{comment: comment})
           |> Repo.update() do
        {:ok, updated_entry} ->
          Ordering.touch(collection.id, DateTime.utc_now(:second))
          updated_entry

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def update_entry_comment(_scope, _collection_id, _game_id, _comment),
    do: {:error, :unauthorized}

  @doc "Builds the data used by an owned collection's CSV and plain-text exports."
  def export_collection(%Scope{user: user} = scope, collection_id) when not is_nil(user) do
    with {:ok, collection} <- owned_collection(user.id, collection_id) do
      entries = collection_entries(scope, collection, user.id, "custom", "asc")
      links_by_game = collection_store_links(Enum.map(entries, & &1.game_id))

      {:ok, collection,
       Enum.map(entries, fn entry ->
         Map.put(entry, :store_links, Map.get(links_by_game, entry.game_id, []))
       end)}
    end
  end

  def export_collection(_scope, _collection_id), do: {:error, :unauthorized}

  @doc "Builds the data used by an owned collection's portable static-site export."
  def export_static_collection(%Scope{user: user} = scope, collection_id)
      when not is_nil(user) do
    with {:ok, collection, entries} <- export_collection(scope, collection_id) do
      games_by_id =
        entries
        |> Enum.map(& &1.game_id)
        |> static_export_games()
        |> Map.new(&{&1.id, &1})

      entries =
        Enum.map(entries, fn entry ->
          game = Map.fetch!(games_by_id, entry.game_id)

          entry
          |> Map.put(:game, game)
          |> Map.put(:playtime_minutes, personal_playtime(game, user))
          |> Map.put(:media_mode, static_media_mode(game, user))
        end)

      {:ok,
       %{
         collection: collection,
         owner_name: user.username,
         entries: entries
       }}
    end
  end

  def export_static_collection(_scope, _collection_id), do: {:error, :unauthorized}

  @doc "Moves a game before another entry in an owned collection's explicit order."
  def move_game(%Scope{user: user} = scope, collection_id, moved_game_id, before_game_id)
      when not is_nil(user) do
    Ordering.move(scope, collection_id, moved_game_id, before_game_id)
  end

  def move_game(_scope, _collection_id, _moved_game_id, _before_game_id),
    do: {:error, :unauthorized}

  @doc "Moves a game one position earlier in an owned collection."
  def move_game_up(%Scope{user: user} = scope, collection_id, game_id)
      when not is_nil(user) do
    Ordering.move_relative(scope, collection_id, game_id, -1)
  end

  def move_game_up(_scope, _collection_id, _game_id), do: {:error, :unauthorized}

  @doc "Moves a game one position later in an owned collection."
  def move_game_down(%Scope{user: user} = scope, collection_id, game_id)
      when not is_nil(user) do
    Ordering.move_relative(scope, collection_id, game_id, 1)
  end

  def move_game_down(_scope, _collection_id, _game_id), do: {:error, :unauthorized}

  @doc "Enables read-only capability-link sharing for an owned collection."
  def enable_sharing(%Scope{user: user}, collection_id) when not is_nil(user) do
    with {:ok, collection} <- owned_collection(user.id, collection_id) do
      if collection.sharing_enabled do
        {:ok, collection}
      else
        collection
        |> Collection.sharing_changeset(%{
          sharing_enabled: true
        })
        |> Repo.update()
      end
    end
  end

  def enable_sharing(_scope, _collection_id), do: {:error, :unauthorized}

  @doc "Disables sharing and invalidates every existing capability link."
  def disable_sharing(%Scope{user: user}, collection_id) when not is_nil(user) do
    with {:ok, collection} <- owned_collection(user.id, collection_id) do
      collection
      |> Collection.sharing_changeset(%{
        sharing_enabled: false,
        share_version: collection.share_version + 1
      })
      |> Repo.update()
    end
  end

  def disable_sharing(_scope, _collection_id), do: {:error, :unauthorized}

  @doc "Invalidates the current capability link and returns a new share version."
  def regenerate_share_link(%Scope{user: user}, collection_id) when not is_nil(user) do
    with {:ok, %{sharing_enabled: true} = collection} <- owned_collection(user.id, collection_id) do
      collection
      |> Collection.sharing_changeset(%{share_version: collection.share_version + 1})
      |> Repo.update()
    else
      {:ok, _private} -> {:error, :sharing_disabled}
      error -> error
    end
  end

  def regenerate_share_link(_scope, _collection_id), do: {:error, :unauthorized}

  @doc "Returns the signed capability token for a currently shared owned collection."
  def share_token(%Scope{user: user}, collection_id) when not is_nil(user) do
    with {:ok, %{sharing_enabled: true} = collection} <- owned_collection(user.id, collection_id) do
      {:ok, sign_share_token(collection)}
    else
      {:ok, _private} -> {:error, :sharing_disabled}
      error -> error
    end
  end

  def share_token(_scope, _collection_id), do: {:error, :unauthorized}

  @doc "Loads a public read-only collection through its signed capability token."
  def get_shared_collection(scope, token), do: get_shared_collection(scope, token, nil, nil)

  def get_shared_collection(scope, token, requested_sort),
    do: get_shared_collection(scope, token, requested_sort, nil)

  def get_shared_collection(
        scope,
        token,
        requested_sort,
        requested_direction
      )
      when (is_nil(scope) or is_struct(scope, Scope)) and is_binary(token) do
    with {:ok, view} <-
           shared_collection_view(scope, token, requested_sort, requested_direction) do
      owner_entries =
        collection_entries(
          view.owner_scope,
          view.collection,
          view.collection.user_id,
          view.sort,
          view.sort_direction
        )

      {:ok, shared_collection_result(view, annotate_viewer_access(scope, owner_entries))}
    else
      _invalid -> {:error, :not_found}
    end
  end

  def get_shared_collection(_scope, _token, _requested_sort, _requested_direction),
    do: {:error, :not_found}

  @doc "Loads one cursor-paginated page from a public collection capability link."
  def get_shared_collection_page(
        scope,
        token,
        requested_sort,
        requested_direction,
        cursor
      )
      when (is_nil(scope) or is_struct(scope, Scope)) and is_binary(token) do
    with {:ok, offset} <- page_offset(cursor),
         {:ok, view} <-
           shared_collection_view(scope, token, requested_sort, requested_direction) do
      {owner_entries, next_cursor} =
        collection_entries_page(
          view.owner_scope,
          view.collection,
          view.collection.user_id,
          view.sort,
          view.sort_direction,
          offset
        )

      {:ok,
       shared_collection_result(view, annotate_viewer_access(scope, owner_entries), %{
         next_cursor: next_cursor,
         total_count: collection_entry_count(view.owner_scope, view.collection.id)
       })}
    else
      _invalid -> {:error, :not_found}
    end
  end

  def get_shared_collection_page(
        _scope,
        _token,
        _requested_sort,
        _requested_direction,
        _cursor
      ),
      do: {:error, :not_found}

  defp owner_collection_view(user_id, collection_id, requested_sort, requested_direction) do
    with {:ok, collection} <- owned_collection(user_id, collection_id) do
      {sort, direction} = resolve_sort(requested_sort, requested_direction)
      {:ok, %{collection: collection, sort: sort, sort_direction: direction}}
    end
  end

  defp shared_collection_view(scope, token, requested_sort, requested_direction) do
    viewer = scope && scope.user

    with {:ok, {collection_id, share_version}} <- verify_share_token(token),
         %Collection{} = collection <-
           Repo.get_by(Collection,
             id: collection_id,
             sharing_enabled: true,
             share_version: share_version
           ),
         %User{} = owner <- Repo.get(User, collection.user_id) do
      {sort, direction} = resolve_sort(requested_sort, requested_direction)

      {:ok,
       %{
         collection: collection,
         owner_scope: Scope.for_user(owner),
         owner_name: owner.username,
         viewer_is_owner: not is_nil(viewer) and collection.user_id == viewer.id,
         sort: sort,
         sort_direction: direction
       }}
    else
      _invalid -> {:error, :not_found}
    end
  end

  defp shared_collection_result(view, entries, extra \\ %{}) do
    Map.merge(
      %{
        collection: %{
          id: view.collection.id,
          name: view.collection.name
        },
        owner_name: view.owner_name,
        viewer_is_owner: view.viewer_is_owner,
        sort: view.sort,
        sort_direction: view.sort_direction,
        entries: entries
      },
      extra
    )
  end

  defp annotate_viewer_access(scope, entries) do
    viewer_game_ids = accessible_entry_ids(scope, entries)

    Enum.map(entries, fn entry ->
      Map.put(entry, :viewer_can_open, MapSet.member?(viewer_game_ids, entry.game_id))
    end)
  end

  defp owned_collection(user_id, collection_id) do
    case Params.positive_integer(collection_id) do
      nil ->
        {:error, :not_found}

      id ->
        case Repo.get_by(Collection, id: id, user_id: user_id) do
          nil -> {:error, :not_found}
          collection -> {:ok, collection}
        end
    end
  end

  defp owned_collection_or_rollback(user_id, collection_id) do
    case owned_collection(user_id, collection_id) do
      {:ok, collection} -> collection
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp collection_entries(scope, collection, rating_user_id, sort, direction) do
    scope
    |> collection_entries_query(collection, rating_user_id, sort, direction)
    |> Repo.all()
  end

  defp collection_entries_page(scope, collection, rating_user_id, sort, direction, offset) do
    rows =
      scope
      |> collection_entries_query(collection, rating_user_id, sort, direction)
      |> limit(^(@collection_page_size + 1))
      |> offset(^offset)
      |> Repo.all()

    if length(rows) > @collection_page_size do
      {Enum.take(rows, @collection_page_size), offset + @collection_page_size}
    else
      {rows, nil}
    end
  end

  defp collection_entries_query(scope, collection, rating_user_id, sort, direction) do
    from(entry in CollectionGame,
      as: :entry,
      join: game in Game,
      as: :game,
      on: game.id == entry.game_id,
      left_join: rating in UserGameState,
      as: :rating,
      on: rating.game_id == game.id and rating.user_id == ^rating_user_id,
      left_join: cover in MediaAsset,
      on: cover.game_id == game.id and cover.kind == "cover" and cover.cache_status == "ready",
      where:
        entry.collection_id == ^collection.id and
          game.id in subquery(Access.game_ids(scope)),
      group_by: [
        entry.id,
        entry.game_id,
        entry.position,
        entry.comment,
        game.title,
        game.normalized_title,
        game.slug,
        game.release_date,
        game.release_year,
        game.rating,
        rating.rating
      ],
      select: %{
        id: entry.id,
        game_id: entry.game_id,
        position: entry.position,
        comment: entry.comment,
        title: game.title,
        slug: game.slug,
        release_date: game.release_date,
        release_year: game.release_year,
        igdb_rating: game.rating,
        personal_rating: rating.rating,
        cover_id: min(cover.id)
      }
    )
    |> order_collection_entries(sort, direction)
  end

  defp collection_entry_count(scope, collection_id) do
    Repo.one(
      from entry in CollectionGame,
        where:
          entry.collection_id == ^collection_id and
            entry.game_id in subquery(Access.game_ids(scope)),
        select: count(entry.id)
    )
  end

  defp accessible_entry_ids(_scope, []), do: MapSet.new()

  defp accessible_entry_ids(nil, _entries), do: MapSet.new()

  defp accessible_entry_ids(%Scope{user: nil}, _entries), do: MapSet.new()

  defp accessible_entry_ids(scope, entries) do
    Repo.all(
      from game in Game,
        where:
          game.id in ^Enum.map(entries, & &1.game_id) and
            game.id in subquery(Access.game_ids(scope)),
        select: game.id
    )
    |> MapSet.new()
  end

  defp static_export_games([]), do: []

  defp static_export_games(game_ids) do
    media_query =
      from asset in MediaAsset,
        order_by: [asc: asset.kind, asc: asset.position, asc: asset.id]

    item_query =
      from item in LibraryItem,
        preload: [:provider_account]

    source_query =
      from source in GameSource,
        order_by: [asc: source.provider, asc: source.id],
        preload: [library_items: ^item_query]

    Repo.all(
      from game in Game,
        where: game.id in ^game_ids,
        preload: [
          media_assets: ^media_query,
          terms: [],
          game_companies: [:company],
          sources: ^source_query
        ]
    )
  end

  defp personal_playtime(game, user) do
    game.sources
    |> Enum.flat_map(& &1.library_items)
    |> Enum.filter(fn item ->
      not item.hidden and is_nil(item.removed_at) and
        item.provider_account.enabled and
        Playtime.personal_account?(item.provider_account, user)
    end)
    |> Enum.map(&(&1.playtime_minutes || 0))
    |> Enum.max(fn -> 0 end)
  end

  defp static_media_mode(game, user) do
    cond do
      Policy.hidden?(game, user) -> :hide
      Policy.blurred?(game, user) -> :blur
      true -> :allow
    end
  end

  defp collection_store_links([]), do: %{}

  defp collection_store_links(game_ids) do
    Repo.all(
      from source in GameSource,
        where: source.game_id in ^game_ids,
        order_by: [asc: source.game_id, asc: source.provider, asc: source.id],
        select: {source.game_id, source.provider, source.external_id, source.source_url}
    )
    |> Enum.reduce(%{}, fn {game_id, provider, external_id, source_url}, links ->
      case StoreLink.build(provider, external_id, source_url) do
        nil ->
          links

        link ->
          Map.update(links, game_id, [link], fn current ->
            if Enum.any?(current, &(&1.url == link.url)), do: current, else: current ++ [link]
          end)
      end
    end)
  end

  defp order_collection_entries(query, "title", "desc") do
    from [entry: entry, game: game] in query,
      order_by: [desc: game.normalized_title, desc: game.id, asc: entry.position]
  end

  defp order_collection_entries(query, "title", _asc) do
    from [entry: entry, game: game] in query,
      order_by: [asc: game.normalized_title, asc: game.id, asc: entry.position]
  end

  defp order_collection_entries(query, "release_date", "desc") do
    from [entry: entry, game: game] in query,
      order_by: [
        asc: is_nil(game.release_date),
        desc: game.release_date,
        asc: entry.position,
        asc: game.normalized_title,
        asc: game.id
      ]
  end

  defp order_collection_entries(query, "release_date", _asc) do
    from [entry: entry, game: game] in query,
      order_by: [
        asc: is_nil(game.release_date),
        asc: game.release_date,
        asc: entry.position,
        asc: game.normalized_title,
        asc: game.id
      ]
  end

  defp order_collection_entries(query, "igdb_rating", "asc") do
    from [entry: entry, game: game] in query,
      order_by: [
        asc: is_nil(game.rating),
        asc: game.rating,
        asc: entry.position,
        asc: game.normalized_title,
        asc: game.id
      ]
  end

  defp order_collection_entries(query, "igdb_rating", _desc) do
    from [entry: entry, game: game] in query,
      order_by: [
        asc: is_nil(game.rating),
        desc: game.rating,
        asc: entry.position,
        asc: game.normalized_title,
        asc: game.id
      ]
  end

  defp order_collection_entries(query, "my_rating", "asc") do
    from [entry: entry, game: game, rating: rating] in query,
      order_by: [
        asc: is_nil(rating.rating),
        asc: rating.rating,
        asc: entry.position,
        asc: game.normalized_title,
        asc: game.id
      ]
  end

  defp order_collection_entries(query, "my_rating", _desc) do
    from [entry: entry, game: game, rating: rating] in query,
      order_by: [
        asc: is_nil(rating.rating),
        desc: rating.rating,
        asc: entry.position,
        asc: game.normalized_title,
        asc: game.id
      ]
  end

  defp order_collection_entries(query, _custom, _direction) do
    from [entry: entry, game: game] in query,
      order_by: [asc: entry.position, asc: game.normalized_title, asc: game.id]
  end

  defp search_games(_scope, _collection, query) when query in [nil, ""], do: []

  defp search_games(scope, collection, query) do
    normalized_query = query |> to_string() |> String.trim() |> Title.normalize()

    if normalized_query == "" do
      []
    else
      pattern = "%#{escape_like(normalized_query)}%"

      Repo.all(
        from game in Game,
          left_join: source in GameSource,
          on: source.game_id == game.id,
          left_join: entry in CollectionGame,
          on: entry.collection_id == ^collection.id and entry.game_id == game.id,
          left_join: cover in MediaAsset,
          on:
            cover.game_id == game.id and cover.kind == "cover" and cover.cache_status == "ready",
          where:
            game.id in subquery(Access.game_ids(scope)) and
              (like(game.normalized_title, ^pattern) or
                 like(source.normalized_source_title, ^pattern)),
          group_by: [
            game.id,
            game.title,
            game.normalized_title,
            game.release_year,
            entry.id
          ],
          order_by: [asc: game.normalized_title, asc: game.id],
          limit: ^@search_limit,
          select: %{
            id: game.id,
            title: game.title,
            release_year: game.release_year,
            added: not is_nil(entry.id),
            cover_id: min(cover.id)
          }
      )
    end
  end

  defp collection_game_counts(_scope, []), do: %{}

  defp collection_game_counts(scope, collection_ids) do
    Repo.all(
      from entry in CollectionGame,
        where:
          entry.collection_id in ^collection_ids and
            entry.game_id in subquery(Access.game_ids(scope)),
        group_by: entry.collection_id,
        select: {entry.collection_id, count(entry.id)}
    )
    |> Map.new()
  end

  defp collection_cover_ids(_scope, []), do: %{}

  defp collection_cover_ids(scope, collection_ids) do
    Repo.all(
      from entry in CollectionGame,
        join: cover in MediaAsset,
        on:
          cover.game_id == entry.game_id and cover.kind == "cover" and
            cover.cache_status == "ready",
        where:
          entry.collection_id in ^collection_ids and
            entry.game_id in subquery(Access.game_ids(scope)),
        group_by: [entry.collection_id, entry.game_id, entry.position],
        order_by: [asc: entry.collection_id, asc: entry.position, asc: entry.game_id],
        select: {entry.collection_id, min(cover.id)}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {collection_id, cover_ids} -> {collection_id, Enum.take(cover_ids, 4)} end)
  end

  defp sign_share_token(collection) do
    Phoenix.Token.sign(
      IriWeb.Endpoint,
      @share_salt,
      {collection.id, collection.share_version}
    )
  end

  defp verify_share_token(token) do
    Phoenix.Token.verify(IriWeb.Endpoint, @share_salt, token, max_age: :infinity)
  end

  defp resolve_sort("release_year", requested_direction),
    do: resolve_sort("release_date", requested_direction)

  defp resolve_sort(requested_sort, requested_direction) when requested_sort in @sort_keys do
    direction =
      if requested_direction in @sort_directions,
        do: requested_direction,
        else: default_direction(requested_sort)

    {requested_sort, direction}
  end

  defp resolve_sort(_requested_sort, _requested_direction), do: {"custom", "asc"}

  defp default_direction("custom"), do: "asc"
  defp default_direction(_sort), do: "desc"

  defp normalize_ids(ids) do
    parsed = ids |> List.wrap() |> Enum.map(&Params.positive_integer/1)

    if Enum.any?(parsed, &is_nil/1) do
      {:error, :invalid_id}
    else
      {:ok, parsed |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp page_offset(nil), do: {:ok, 0}
  defp page_offset(offset) when is_integer(offset) and offset >= 0, do: {:ok, offset}
  defp page_offset(_offset), do: {:error, :invalid_cursor}

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
