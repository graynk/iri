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

defmodule Iri.Integrations.GOG.Reconciler do
  @moduledoc "Transactional projection of a complete GOG public-profile snapshot."

  import Ecto.Query, warn: false

  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{GameSource, LibraryItem, Title}
  alias Iri.Repo

  @insert_batch_size 500

  def reconcile(%ProviderAccount{provider: :gog} = account, games) when is_list(games) do
    with {:ok, normalized_games} <- normalize_games(games) do
      Repo.transact_with_busy_retry(
        fn -> persist_complete_snapshot(account, normalized_games) end,
        mode: :immediate
      )
    end
  end

  defp persist_complete_snapshot(account, games) do
    now = DateTime.utc_now(:second)
    external_ids = Enum.map(games, & &1.external_id)
    existing_sources = existing_source_map(external_ids)

    insert_all_in_batches(
      GameSource,
      Enum.map(games, &source_row(&1, now)),
      conflict_target: [:provider, :external_id],
      on_conflict:
        {:replace,
         [
           :source_title,
           :normalized_source_title,
           :source_url,
           :metadata_snapshot,
           :catalog_kind,
           :updated_at
         ]}
    )

    sources = existing_source_map(external_ids)
    source_ids = Map.values(sources)

    existing_items =
      Repo.all(
        from item in LibraryItem,
          where: item.provider_account_id == ^account.id and item.game_source_id in ^source_ids,
          select: item.game_source_id
      )
      |> MapSet.new()

    insert_all_in_batches(
      LibraryItem,
      Enum.map(games, &library_item_row(&1, sources, account, now)),
      conflict_target: [:provider_account_id, :game_source_id],
      on_conflict:
        {:replace,
         [
           :relationship,
           :hidden,
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

  defp existing_source_map([]), do: %{}

  defp existing_source_map(external_ids) do
    Repo.all(
      from source in GameSource,
        where: source.provider == :gog and source.external_id in ^external_ids,
        select: {source.external_id, source.id}
    )
    |> Map.new()
  end

  defp mark_absent_items_removed(account_id, present_source_ids, now) do
    query =
      from item in LibraryItem,
        join: source in assoc(item, :game_source),
        where:
          item.provider_account_id == ^account_id and source.provider == :gog and
            is_nil(item.removed_at)

    query =
      if present_source_ids == [] do
        query
      else
        from [item, source] in query, where: item.game_source_id not in ^present_source_ids
      end

    {count, _result} =
      Repo.update_all(query, set: [removed_at: now, updated_at: now])

    count
  end

  defp insert_all_in_batches(_schema, [], _options), do: :ok

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

  defp normalize_game(%{"id" => external_id, "title" => title} = game)
       when (is_binary(external_id) or is_integer(external_id)) and is_binary(title) do
    stats = if is_map(game["stats"]), do: game["stats"], else: %{}
    playtime = non_negative_integer(stats["playtime"] || stats["totalPlaytime"] || 0)

    {:ok,
     %{
       external_id: to_string(external_id),
       title: String.trim(title),
       source_url: absolute_url(game["url"], title),
       snapshot: game,
       playtime_minutes: playtime
     }}
  end

  defp normalize_game(_game), do: {:error, :invalid_game_payload}

  defp source_row(game, now) do
    %{
      provider: :gog,
      external_id: game.external_id,
      source_title: game.title,
      normalized_source_title: Title.normalize(game.title),
      source_url: game.source_url,
      metadata_snapshot: game.snapshot,
      catalog_kind: "game",
      manual_lock: false,
      inserted_at: now,
      updated_at: now
    }
  end

  defp library_item_row(game, sources, account, now) do
    %{
      provider_account_id: account.id,
      game_source_id: Map.fetch!(sources, game.external_id),
      relationship: :owned,
      hidden: false,
      playtime_minutes: game.playtime_minutes,
      removed_at: nil,
      inserted_at: now,
      updated_at: now
    }
  end

  defp absolute_url(url, _title) when is_binary(url) do
    URI.merge("https://www.gog.com", url) |> URI.to_string()
  rescue
    _error -> nil
  end

  defp absolute_url(_url, title), do: "https://www.gog.com/game/#{Title.slug(title)}"

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(value) when is_float(value) and value >= 0, do: trunc(value)

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> 0
    end
  end

  defp non_negative_integer(_value), do: 0
end
