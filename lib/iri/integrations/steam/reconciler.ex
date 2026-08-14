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

defmodule Iri.Integrations.Steam.Reconciler do
  @moduledoc "Transactional, idempotent projection of a complete Steam library response."

  import Ecto.Query, warn: false

  alias Iri.Integrations.ProviderAccount
  alias Iri.Integrations.Steam.StoreClient
  alias Iri.Library.{GameSource, LibraryItem, Title}
  alias Iri.Repo

  @insert_batch_size 500

  def reconcile(%ProviderAccount{provider: :steam} = account, games) when is_list(games) do
    with false <- games == [],
         {:ok, normalized_games} <- normalize_games(games) do
      Repo.transact_with_busy_retry(
        fn -> persist_complete_snapshot(account, normalized_games) end,
        mode: :immediate
      )
    else
      true -> {:error, :incomplete_library}
      error -> error
    end
  end

  defp persist_complete_snapshot(account, games) do
    now = DateTime.utc_now(:second)
    external_ids = Enum.map(games, & &1.external_id)

    existing_sources =
      Repo.all(
        from source in GameSource,
          where: source.provider == :steam and source.external_id in ^external_ids,
          select: {source.external_id, source.id}
      )
      |> Map.new()

    source_rows = Enum.map(games, &source_row(&1, now))

    insert_all_in_batches(
      GameSource,
      source_rows,
      conflict_target: [:provider, :external_id],
      on_conflict:
        {:replace,
         [
           :source_title,
           :normalized_source_title,
           :source_url,
           :metadata_snapshot,
           :updated_at
         ]}
    )

    sources =
      Repo.all(
        from source in GameSource,
          where: source.provider == :steam and source.external_id in ^external_ids,
          select: {source.external_id, source.id}
      )
      |> Map.new()

    source_ids = Map.values(sources)

    existing_items =
      Repo.all(
        from item in LibraryItem,
          where: item.provider_account_id == ^account.id and item.game_source_id in ^source_ids,
          select: item.game_source_id
      )
      |> MapSet.new()

    item_rows = Enum.map(games, &library_item_row(&1, sources, account, now))

    insert_all_in_batches(
      LibraryItem,
      item_rows,
      conflict_target: [:provider_account_id, :game_source_id],
      on_conflict:
        {:replace,
         [
           :playtime_minutes,
           :removed_at,
           :updated_at
         ]}
    )

    removed_count = mark_absent_items_removed(account.id, source_ids, now)

    inserted_count = Enum.count(source_ids, &(not MapSet.member?(existing_items, &1)))

    {:ok,
     %{
       discovered_count: length(games),
       inserted_count: inserted_count,
       updated_count: length(games) - inserted_count,
       removed_count: removed_count,
       new_source_count: Enum.count(external_ids, &(not Map.has_key?(existing_sources, &1)))
     }}
  end

  defp mark_absent_items_removed(account_id, present_source_ids, now) do
    query =
      from item in LibraryItem,
        join: source in assoc(item, :game_source),
        where:
          item.provider_account_id == ^account_id and source.provider == :steam and
            is_nil(item.removed_at) and item.game_source_id not in ^present_source_ids and
            not item.manually_added

    {count, _result} =
      Repo.update_all(query, set: [removed_at: now, updated_at: now])

    count
  end

  defp insert_all_in_batches(schema, rows, options) do
    rows
    |> Enum.chunk_every(@insert_batch_size)
    |> Enum.each(&Repo.insert_all(schema, &1, options))
  end

  defp normalize_games(games) do
    Enum.reduce_while(games, {:ok, []}, fn game, {:ok, normalized} ->
      case normalize_game(game) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end)
  end

  defp normalize_game(%{"appid" => appid} = game) when is_integer(appid) do
    external_id = Integer.to_string(appid)
    name = usable_title(game["name"], external_id)

    {:ok,
     %{
       external_id: external_id,
       title: name,
       normalized_title: Title.normalize(name),
       source_url: "https://store.steampowered.com/app/#{external_id}",
       snapshot: game,
       playtime_minutes: non_negative_integer(game["playtime_forever"])
     }}
  end

  defp normalize_game(_game), do: {:error, :invalid_game_payload}

  defp usable_title(name, _external_id) when is_binary(name) and name != "", do: name
  defp usable_title(_name, external_id), do: "Steam App #{external_id}"

  defp source_row(game, now) do
    %{
      provider: :steam,
      external_id: game.external_id,
      source_title: game.title,
      normalized_source_title: game.normalized_title,
      source_url: game.source_url,
      metadata_snapshot: game.snapshot,
      catalog_kind: StoreClient.catalog_kind_from_title(game.title),
      manual_lock: false,
      inserted_at: now,
      updated_at: now
    }
  end

  defp library_item_row(game, sources, account, now) do
    %{
      provider_account_id: account.id,
      game_source_id: Map.fetch!(sources, game.external_id),
      hidden: false,
      playtime_minutes: game.playtime_minutes,
      removed_at: nil,
      inserted_at: now,
      updated_at: now
    }
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0
end
