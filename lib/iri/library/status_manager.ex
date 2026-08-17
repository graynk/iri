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

defmodule Iri.Library.StatusManager do
  @moduledoc "Compact, scoped completion-status browsing for bulk management."

  import Ecto.Query, warn: false

  alias Iri.Accounts.Scope
  alias Iri.Library.{Access, Game, GameSource, LibraryItem, MediaAsset, Playtime}
  alias Iri.Library.{Title, UserGameState}
  alias Iri.Params
  alias Iri.Repo

  @page_size 100
  @sorts ~w(title release_date playtime)
  @statuses ~w(all backlog playing completed dropped not_played)

  @doc "Returns a paginated, scoped game list for bulk state and rating management."
  def list_games(scope, params \\ %{}, options \\ [])

  def list_games(%Scope{user: user} = scope, params, options)
      when not is_nil(user) and is_list(options) do
    filters = normalize_params(params)
    excluded_ids = options |> Keyword.get(:exclude_ids, []) |> normalize_ids()

    query =
      from game in Game,
        as: :game,
        left_join: user_state in UserGameState,
        as: :user_state,
        on: user_state.game_id == game.id and user_state.user_id == ^user.id,
        where: game.id in subquery(Access.game_ids(scope))

    query =
      query
      |> exclude_games(excluded_ids)
      |> apply_search(filters["q"])
      |> apply_status(filters["status"])

    total_count = Repo.aggregate(query, :count, :id)
    page_count = max(Integer.ceil_div(total_count, @page_size), 1)
    page_number = min(filters["page"], page_count)

    page_query =
      if filters["sort"] == "playtime",
        do: with_personal_playtime(query, user),
        else: query

    games =
      page_query
      |> apply_sort(filters["sort"], filters["direction"])
      |> offset(^((page_number - 1) * @page_size))
      |> limit(^@page_size)
      |> Repo.all()
      |> preload_rows(user)

    {:ok,
     %{
       entries: games,
       total_count: total_count,
       page: page_number,
       page_count: page_count,
       page_size: @page_size,
       filters: Map.put(filters, "page", page_number)
     }}
  end

  def list_games(_scope, _params, _options), do: {:error, :unauthorized}

  @doc "Loads a complete set of accessible games for a bulk operation, preserving no hidden IDs."
  def list_games_by_ids(%Scope{user: user} = scope, ids) when not is_nil(user) do
    ids = normalize_ids(ids)

    games =
      Repo.all(
        from game in Game,
          where: game.id in ^ids and game.id in subquery(Access.game_ids(scope)),
          order_by: [asc: game.normalized_title, asc: game.id]
      )
      |> preload_rows(user)

    if length(games) == length(ids), do: {:ok, games}, else: {:error, :not_found}
  end

  def list_games_by_ids(_scope, _ids), do: {:error, :unauthorized}

  defp preload_rows(games, user) do
    cover_query =
      from asset in MediaAsset,
        where: asset.kind == "cover" and asset.cache_status == "ready",
        order_by: [asc: asset.position, asc: asset.id]

    state_query = from state in UserGameState, where: state.user_id == ^user.id

    # Playtime is the viewer's own only, so a shared game never shows another
    # user's hours.
    personal_account_filter = Playtime.personal_account_filter(user)

    item_query =
      from item in LibraryItem,
        join: account in assoc(item, :provider_account),
        as: :account,
        where: ^personal_account_filter,
        where: account.enabled and not item.hidden and is_nil(item.removed_at)

    source_query =
      from source in GameSource,
        preload: [library_items: ^item_query]

    Repo.preload(games,
      media_assets: cover_query,
      user_states: state_query,
      sources: source_query
    )
  end

  defp apply_search(query, ""), do: query

  defp apply_search(query, search) do
    pattern = "%#{escape_like(Title.normalize(search))}%"
    from [game: game] in query, where: like(game.normalized_title, ^pattern)
  end

  defp exclude_games(query, []), do: query

  defp exclude_games(query, excluded_ids) do
    from [game: game] in query, where: game.id not in ^excluded_ids
  end

  defp apply_status(query, "backlog") do
    from [user_state: state] in query, where: state.state == "backlog"
  end

  defp apply_status(query, "completed") do
    from [user_state: state] in query, where: state.state == "completed"
  end

  defp apply_status(query, "dropped") do
    from [user_state: state] in query, where: state.state == "dropped"
  end

  defp apply_status(query, "playing") do
    from [user_state: state] in query, where: state.state == "playing"
  end

  defp apply_status(query, "not_played") do
    from [user_state: state] in query,
      where:
        is_nil(state.state) or state.state not in ["backlog", "playing", "completed", "dropped"]
  end

  defp apply_status(query, _all), do: query

  defp with_personal_playtime(query, user) do
    personal_account_filter = Playtime.personal_account_filter(user)

    personal_playtime =
      from item in LibraryItem,
        join: source in GameSource,
        on: source.id == item.game_source_id,
        join: account in assoc(item, :provider_account),
        as: :account,
        where: ^personal_account_filter,
        where:
          account.enabled and not item.hidden and is_nil(item.removed_at) and
            not is_nil(source.game_id),
        group_by: source.game_id,
        select: %{game_id: source.game_id, minutes: max(item.playtime_minutes)}

    from [game: game] in query,
      left_join: playtime in subquery(personal_playtime),
      as: :playtime,
      on: playtime.game_id == game.id
  end

  defp apply_sort(query, "release_date", "desc") do
    from [game: game] in query,
      order_by: [
        asc: is_nil(game.release_date),
        desc: game.release_date,
        asc: game.normalized_title,
        asc: game.id
      ]
  end

  defp apply_sort(query, "release_date", _asc) do
    from [game: game] in query,
      order_by: [
        asc: is_nil(game.release_date),
        asc: game.release_date,
        asc: game.normalized_title,
        asc: game.id
      ]
  end

  defp apply_sort(query, "playtime", "desc") do
    from [game: game, playtime: playtime] in query,
      order_by: [
        desc: fragment("COALESCE(?, 0)", playtime.minutes),
        asc: game.normalized_title,
        asc: game.id
      ]
  end

  defp apply_sort(query, "playtime", _asc) do
    from [game: game, playtime: playtime] in query,
      order_by: [
        asc: fragment("COALESCE(?, 0)", playtime.minutes),
        asc: game.normalized_title,
        asc: game.id
      ]
  end

  defp apply_sort(query, _title, "desc") do
    from [game: game] in query,
      order_by: [desc: game.normalized_title, desc: game.id]
  end

  defp apply_sort(query, _title, _asc) do
    from [game: game] in query,
      order_by: [asc: game.normalized_title, asc: game.id]
  end

  defp normalize_params(params) do
    requested_sort = Map.get(params, "sort", "title")

    %{
      "q" => params |> Map.get("q", "") |> text_value() |> String.trim(),
      "status" => params |> Map.get("status", "all") |> allowed(@statuses, "all"),
      "sort" => normalize_sort(requested_sort),
      "direction" => normalize_direction(Map.get(params, "direction"), requested_sort),
      "page" => params |> Map.get("page", 1) |> Params.positive_integer() || 1
    }
  end

  defp normalize_sort("release_desc"), do: "release_date"
  defp normalize_sort("release_asc"), do: "release_date"
  defp normalize_sort("release_year"), do: "release_date"
  defp normalize_sort(value), do: allowed(value, @sorts, "title")

  defp normalize_direction(value, _sort) when value in ["asc", "desc"], do: value
  defp normalize_direction(nil, "release_desc"), do: "desc"
  defp normalize_direction(_value, _sort), do: "asc"

  defp allowed(value, values, default), do: if(value in values, do: value, else: default)

  defp normalize_ids(ids) do
    ids
    |> List.wrap()
    |> Enum.map(&Params.positive_integer/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp text_value(value) when is_binary(value), do: value
  defp text_value(_value), do: ""

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
