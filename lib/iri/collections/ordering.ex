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

defmodule Iri.Collections.Ordering do
  @moduledoc "Maintains dense explicit positions for user-owned collection entries."

  import Ecto.Query, warn: false

  alias Iri.Accounts.Scope
  alias Iri.Collections.{Collection, CollectionGame}
  alias Iri.Library.{Access, Game}
  alias Iri.Params
  alias Iri.Repo

  @doc "Returns the next append position for a collection."
  def next_position(collection_id) do
    from(entry in CollectionGame,
      where: entry.collection_id == ^collection_id,
      select: coalesce(max(entry.position), -1) + 1
    )
    |> Repo.one()
  end

  @doc "Moves a collection entry before another entry, or to the end when `before_game_id` is nil."
  def move(%Scope{user: user} = scope, collection_id, moved_game_id, before_game_id)
      when not is_nil(user) do
    with moved_game_id when not is_nil(moved_game_id) <- Params.positive_integer(moved_game_id),
         {:ok, before_game_id} <- optional_positive_integer(before_game_id) do
      Repo.transaction(fn ->
        collection = owned_collection_or_rollback(user.id, collection_id)
        entries = ordered_collection_entries(collection.id)

        validate_reorder_games!(scope, entries, [moved_game_id, before_game_id])

        entries
        |> move_entry_before(moved_game_id, before_game_id)
        |> persist_order_if_changed(entries, collection.id)

        :ok
      end)
    else
      _invalid -> {:error, :not_found}
    end
  end

  @doc "Moves a collection entry by one position; only offsets `-1` and `1` are accepted."
  def move_relative(%Scope{user: user} = scope, collection_id, game_id, offset)
      when not is_nil(user) and offset in [-1, 1] do
    case Params.positive_integer(game_id) do
      nil ->
        {:error, :not_found}

      game_id ->
        Repo.transaction(fn ->
          collection = owned_collection_or_rollback(user.id, collection_id)
          entries = ordered_collection_entries(collection.id)

          validate_reorder_games!(scope, entries, [game_id])

          entries
          |> move_entry_relative(game_id, offset)
          |> persist_order_if_changed(entries, collection.id)

          :ok
        end)
    end
  end

  @doc "Rewrites a collection's positions into a dense zero-based sequence."
  def normalize_positions(collection_id) do
    Repo.all(
      from entry in CollectionGame,
        where: entry.collection_id == ^collection_id,
        order_by: [asc: entry.position, asc: entry.id],
        select: entry.id
    )
    |> Enum.with_index()
    |> Enum.each(fn {entry_id, position} ->
      from(entry in CollectionGame, where: entry.id == ^entry_id)
      |> Repo.update_all(set: [position: position])
    end)
  end

  @doc "Updates a collection timestamp after an entry-level mutation."
  def touch(collection_id, now) do
    from(collection in Collection, where: collection.id == ^collection_id)
    |> Repo.update_all(set: [updated_at: now])
  end

  defp owned_collection_or_rollback(user_id, collection_id) do
    case Params.positive_integer(collection_id) do
      nil ->
        Repo.rollback(:not_found)

      id ->
        case Repo.get_by(Collection, id: id, user_id: user_id) do
          %Collection{} = collection -> collection
          nil -> Repo.rollback(:not_found)
        end
    end
  end

  defp ordered_collection_entries(collection_id) do
    Repo.all(
      from entry in CollectionGame,
        where: entry.collection_id == ^collection_id,
        order_by: [asc: entry.position, asc: entry.id],
        select: %{id: entry.id, game_id: entry.game_id, position: entry.position}
    )
  end

  defp validate_reorder_games!(scope, entries, requested_game_ids) do
    requested_game_ids = requested_game_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
    member_ids = entries |> Enum.map(& &1.game_id) |> MapSet.new()

    accessible_ids =
      Repo.all(
        from game in Game,
          where: game.id in ^requested_game_ids and game.id in subquery(Access.game_ids(scope)),
          select: game.id
      )
      |> MapSet.new()

    unless Enum.all?(requested_game_ids, fn game_id ->
             MapSet.member?(member_ids, game_id) and MapSet.member?(accessible_ids, game_id)
           end) do
      Repo.rollback(:not_found)
    end
  end

  defp move_entry_before(entries, moved_game_id, moved_game_id), do: entries

  defp move_entry_before(entries, moved_game_id, before_game_id) do
    {moved_entry, remaining} = pop_entry(entries, moved_game_id)

    case before_game_id do
      nil ->
        remaining ++ [moved_entry]

      before_game_id ->
        before_index = Enum.find_index(remaining, &(&1.game_id == before_game_id))
        List.insert_at(remaining, before_index, moved_entry)
    end
  end

  defp move_entry_relative(entries, game_id, offset) do
    current_index = Enum.find_index(entries, &(&1.game_id == game_id))
    target_index = current_index + offset
    target_index = target_index |> max(0) |> min(length(entries) - 1)

    if current_index == target_index do
      entries
    else
      {moved_entry, remaining} = List.pop_at(entries, current_index)
      List.insert_at(remaining, target_index, moved_entry)
    end
  end

  defp pop_entry(entries, game_id) do
    index = Enum.find_index(entries, &(&1.game_id == game_id))
    {entry, remaining} = List.pop_at(entries, index)
    {entry, remaining}
  end

  defp persist_order_if_changed(entries, previous_entries, collection_id) do
    if Enum.map(entries, & &1.id) != Enum.map(previous_entries, & &1.id) do
      now = DateTime.utc_now(:second)

      entries
      |> Enum.with_index()
      |> Enum.each(fn {entry, position} ->
        from(collection_game in CollectionGame,
          where:
            collection_game.id == ^entry.id and collection_game.collection_id == ^collection_id
        )
        |> Repo.update_all(set: [position: position, updated_at: now])
      end)

      touch(collection_id, now)
    end
  end

  defp optional_positive_integer(value) when value in [nil, ""], do: {:ok, nil}

  defp optional_positive_integer(value) do
    case Params.positive_integer(value) do
      nil -> {:error, :invalid_id}
      integer -> {:ok, integer}
    end
  end
end
