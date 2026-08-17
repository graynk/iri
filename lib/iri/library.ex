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

defmodule Iri.Library do
  @moduledoc "Canonical games, source records, ownership, and local organization."

  import Ecto.Query, warn: false

  alias Iri.Accounts.Scope
  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{Access, Game, GameSource, LibraryItem, Personalization, Playtime}
  alias Iri.Library.{TaxonomyTerm, Title, UserGameState}
  alias Iri.Media.Classification
  alias Iri.Params
  alias Iri.Repo

  @page_size 48
  @tag_kinds ["keyword", "player_perspective"]

  @doc """
  Returns one page of canonical library entries visible to `scope`.

  The result collapses equivalent store sources onto one canonical game while
  retaining unmatched store-only sources. `params` accepts the library UI's
  search, filter, sort, direction, and page values.
  """
  def list_source_games(scope, params \\ %{})

  def list_source_games(%Scope{user: user} = scope, params) when not is_nil(user) do
    filters = normalize_filter_params(params)
    search = filters["q"] |> Title.normalize()
    requested_page = params |> Map.get("page", 1) |> Params.positive_integer() || 1
    accessible_account_ids = Access.account_ids(scope)
    owned_source_ids = owned_source_ids(filters, accessible_account_ids)

    canonical_source_ids =
      from source in GameSource,
        where: source.id in subquery(owned_source_ids) and not is_nil(source.game_id),
        group_by: source.game_id,
        select: min(source.id)

    query =
      from source in GameSource,
        as: :source,
        left_join: game in assoc(source, :game),
        as: :game,
        left_join: user_state in UserGameState,
        as: :user_state,
        on: user_state.game_id == game.id and user_state.user_id == ^user.id,
        where:
          source.id in subquery(owned_source_ids) and
            (is_nil(source.game_id) or source.id in subquery(canonical_source_ids))

    query = apply_taxonomy_filters(query, filters)
    query = apply_tag_filters(query, filters["tag_ids"])
    query = apply_compatibility_filters(query, filters, owned_source_ids)
    query = apply_state_filters(query, filters, user.id)
    query = apply_search(query, search)

    count =
      query
      |> exclude(:select)
      |> select([source: source], count(source.id))
      |> Repo.one()

    page_count = max(Integer.ceil_div(count, @page_size), 1)
    page_number = min(requested_page, page_count)

    page_query =
      if filters["sort"] == "playtime",
        do: with_personal_playtime(query, user),
        else: query

    page =
      page_query
      |> apply_sort(filters["sort"], filters["direction"])
      |> limit(^@page_size)
      |> offset(^((page_number - 1) * @page_size))
      |> Repo.all()

    items_query =
      from item in LibraryItem,
        where:
          not item.hidden and is_nil(item.removed_at) and
            item.provider_account_id in subquery(accessible_account_ids),
        preload: [:provider_account]

    state_query = from state in UserGameState, where: state.user_id == ^user.id

    card_media_query =
      from asset in Iri.Library.MediaAsset,
        where:
          (asset.kind == "cover" and asset.cache_status == "ready") or
            (asset.kind == "screenshot" and asset.position <= 4),
        order_by: [asc: asset.position, asc: asset.id]

    page =
      Repo.preload(page,
        library_items: items_query,
        game: [
          :terms,
          media_assets: card_media_query,
          user_states: state_query,
          sources: [library_items: items_query]
        ]
      )

    {:ok,
     %{
       entries: page,
       total_count: count,
       page: page_number,
       page_count: page_count,
       page_size: @page_size,
       search: search,
       filters: filters
     }}
  end

  def list_source_games(_scope, _params), do: {:error, :unauthorized}

  @doc "Returns the signed-in user's completion-state totals for accessible games."
  def completion_state_counts(%Scope{user: user} = scope) when not is_nil(user) do
    counts =
      Repo.all(
        from state in UserGameState,
          where:
            state.user_id == ^user.id and
              state.game_id in subquery(Access.game_ids(scope)) and
              state.state in ["completed", "dropped", "playing", "backlog"],
          group_by: state.state,
          select: {state.state, count(state.game_id)}
      )
      |> Map.new()

    {:ok,
     Map.merge(
       %{"completed" => 0, "dropped" => 0, "playing" => 0, "backlog" => 0},
       counts
     )}
  end

  def completion_state_counts(_scope), do: {:error, :unauthorized}

  @doc "Returns the accessible accounts and taxonomy terms used by the library filter panel."
  def list_filter_options(%Scope{user: user} = scope) when not is_nil(user) do
    accessible_account_ids = Access.account_ids(scope)

    accounts =
      Repo.all(
        from account in ProviderAccount,
          join: item in LibraryItem,
          on: item.provider_account_id == account.id,
          join: source in GameSource,
          on: source.id == item.game_source_id,
          where:
            account.id in subquery(accessible_account_ids) and not item.hidden and
              is_nil(item.removed_at) and
              (is_nil(source.match_method) or source.match_method != "rejected"),
          distinct: true
      )
      |> Repo.preload(:owner_user)
      |> Enum.sort_by(&account_filter_sort_key(&1, user))

    owned_game_ids =
      from source in GameSource,
        join: item in assoc(source, :library_items),
        join: account in assoc(item, :provider_account),
        where:
          not item.hidden and is_nil(item.removed_at) and account.enabled and
            account.id in subquery(accessible_account_ids) and
            not is_nil(source.game_id),
        select: source.game_id,
        distinct: true

    terms =
      Repo.all(
        from term in TaxonomyTerm,
          join: game_term in "game_terms",
          on: field(game_term, :taxonomy_term_id) == term.id,
          where:
            term.kind in ["genre", "theme", "game_mode"] and
              not (term.kind == "game_mode" and
                     fragment("lower(?)", term.name) == "battle royale") and
              field(game_term, :game_id) in subquery(owned_game_ids),
          distinct: true,
          order_by: [asc: term.name, asc: term.id]
      )

    grouped =
      terms
      |> TaxonomyTerm.deduplicate()
      |> Enum.group_by(&TaxonomyTerm.presentation_kind/1)

    {:ok,
     %{
       accounts: accounts,
       genres: Map.get(grouped, "genre", []),
       themes: Map.get(grouped, "theme", []),
       game_modes: Map.get(grouped, "game_mode", [])
     }}
  end

  def list_filter_options(_scope), do: {:error, :unauthorized}

  # Filter library order: the account the user starred as theirs first, then
  # their own stores, their custom library, shared stores, and shared custom
  # libraries; alphabetical within each group.
  defp account_filter_sort_key(account, user) do
    starred? = not is_nil(user.main_steam_account_id) and account.id == user.main_steam_account_id
    own? = account.owner_user_id == user.id
    custom? = account.provider == :custom

    group =
      cond do
        starred? -> -1
        own? and not custom? -> 0
        own? and custom? -> 1
        not own? and not custom? -> 2
        true -> 3
      end

    {group, Atom.to_string(account.provider),
     String.downcase(account.display_name || account.external_user_id), account.id}
  end

  @doc """
  Searches tags available in the viewer's library.

  Tags deliberately combine provider keywords and player perspectives. Results
  are deduplicated by normalized name and exclude already selected equivalents.
  """
  def list_tag_suggestions(scope, search, selected_ids \\ [])

  def list_tag_suggestions(%Scope{user: user} = scope, search, selected_ids)
      when not is_nil(user) do
    search = search |> text_value() |> String.trim() |> String.downcase()

    if search == "" do
      {:ok, []}
    else
      owned_game_ids = Access.game_ids(scope)

      selected_ids = selected_ids |> normalize_ids() |> Enum.map(&String.to_integer/1)
      excluded_ids = selected_ids |> tag_id_groups() |> List.flatten()
      pattern = "%#{escape_like(search)}%"
      prefix_pattern = "#{escape_like(search)}%"

      suggestions =
        Repo.all(
          from term in TaxonomyTerm,
            join: game_term in "game_terms",
            on: field(game_term, :taxonomy_term_id) == term.id,
            where:
              term.kind in @tag_kinds and
                fragment("lower(?) LIKE ? ESCAPE '\\'", term.name, ^pattern) and
                field(game_term, :game_id) in subquery(owned_game_ids) and
                term.id not in ^excluded_ids,
            distinct: true,
            order_by: [
              asc:
                fragment(
                  "CASE WHEN lower(?) = ? THEN 0 WHEN lower(?) LIKE ? ESCAPE '\\' THEN 1 ELSE 2 END",
                  term.name,
                  ^search,
                  term.name,
                  ^prefix_pattern
                ),
              asc: fragment("lower(?)", term.name),
              asc: term.id
            ],
            limit: 200
        )
        |> canonical_tag_terms()
        |> Enum.take(12)

      {:ok, suggestions}
    end
  end

  def list_tag_suggestions(_scope, _search, _selected_ids), do: {:error, :unauthorized}

  @doc "Returns canonical display labels for selected library tag IDs."
  def list_filter_tags(%Scope{user: user} = scope, ids) when not is_nil(user) do
    ids = ids |> normalize_ids() |> Enum.map(&String.to_integer/1)
    owned_game_ids = Access.game_ids(scope)

    selected =
      Repo.all(
        from term in TaxonomyTerm,
          join: game_term in "game_terms",
          on: field(game_term, :taxonomy_term_id) == term.id,
          where:
            term.kind in @tag_kinds and term.id in ^ids and
              field(game_term, :game_id) in subquery(owned_game_ids),
          distinct: true,
          order_by: [asc: term.name, asc: term.id]
      )

    {:ok, canonical_tag_terms(selected)}
  end

  def list_filter_tags(_scope, _ids), do: {:error, :unauthorized}

  @doc "Loads one accessible canonical game with the associations required by its detail page."
  def get_game_by_slug(%Scope{user: user} = scope, slug) when not is_nil(user) do
    accessible_account_ids = Access.account_ids(scope)

    query =
      from game in Game,
        join: source in assoc(game, :sources),
        join: item in assoc(source, :library_items),
        join: account in assoc(item, :provider_account),
        where:
          game.slug == ^slug and not item.hidden and is_nil(item.removed_at) and
            account.enabled and account.id in subquery(accessible_account_ids),
        distinct: true

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      game ->
        items_query =
          from item in LibraryItem,
            where:
              not item.hidden and is_nil(item.removed_at) and
                item.provider_account_id in subquery(accessible_account_ids),
            preload: [:provider_account]

        state_query = from state in UserGameState, where: state.user_id == ^user.id

        {:ok,
         Repo.preload(game, [
           :terms,
           :media_assets,
           user_states: state_query,
           game_companies: :company,
           sources: [library_items: items_query]
         ])}
    end
  end

  def get_game_by_slug(_scope, _slug), do: {:error, :unauthorized}

  @doc "Sets or clears the current user's completion state for an accessible game."
  defdelegate set_game_state(scope, game_id, state),
    to: Personalization,
    as: :set_completion_state

  @doc "Clears the current user's completion state for an accessible game."
  def clear_game_state(scope, game_id),
    do: Personalization.set_completion_state(scope, game_id, nil)

  @doc "Marks an accessible game's media as not sensitive. Administrators only."
  def mark_game_not_sensitive(%Scope{} = scope, game_id) do
    with true <- Scope.admin?(scope),
         game_id when not is_nil(game_id) <- Params.positive_integer(game_id),
         true <- game_accessible?(scope, game_id) do
      Classification.set_not_sensitive(game_id)
    else
      false -> {:error, :unauthorized}
      _other -> {:error, :not_found}
    end
  end

  def mark_game_not_sensitive(_scope, _game_id), do: {:error, :unauthorized}

  @doc "Marks an accessible game's media as sensitive. Administrators only."
  def mark_game_sensitive(%Scope{} = scope, game_id) do
    with true <- Scope.admin?(scope),
         game_id when not is_nil(game_id) <- Params.positive_integer(game_id),
         true <- game_accessible?(scope, game_id) do
      Classification.set_sensitive(game_id)
    else
      false -> {:error, :unauthorized}
      _other -> {:error, :not_found}
    end
  end

  def mark_game_sensitive(_scope, _game_id), do: {:error, :unauthorized}

  @doc """
  Deletes provider sources and canonical games that no library item references.

  Removing a provider account cascades its library items away but leaves its
  sources and their canonical games behind, where nothing can reach them. This
  removes that residue together with everything the database cascades from it:
  cached media, personal completion state and ratings, collection entries, and
  matching history.

  Returns the number of rows deleted from each table.
  """
  def prune_orphaned_games do
    Repo.transact(fn ->
      referenced_sources = from item in LibraryItem, select: item.game_source_id

      {sources, _} =
        Repo.delete_all(
          from source in GameSource, where: source.id not in subquery(referenced_sources)
        )

      # Sources deleted above no longer hold their games back, so this second
      # pass catches games whose only sources just went away.
      referenced_games =
        from source in GameSource, where: not is_nil(source.game_id), select: source.game_id

      {games, _} =
        Repo.delete_all(from game in Game, where: game.id not in subquery(referenced_games))

      {:ok, %{sources: sources, games: games}}
    end)
  end

  defp game_accessible?(scope, game_id) do
    Repo.exists?(
      from game in Game,
        where: game.id == ^game_id and game.id in subquery(Access.game_ids(scope))
    )
  end

  defp owned_source_ids(filters, accessible_account_ids) do
    query =
      from item in LibraryItem,
        join: account in assoc(item, :provider_account),
        join: source in assoc(item, :game_source),
        where:
          not item.hidden and is_nil(item.removed_at) and account.enabled and
            account.id in subquery(accessible_account_ids) and
            (is_nil(source.match_method) or source.match_method != "rejected") and
            (is_nil(source.catalog_kind) or source.catalog_kind in ["game", "unknown"]),
        select: source.id

    providers = Enum.map(filters["providers"], &String.to_existing_atom/1)

    query =
      if providers == [] do
        query
      else
        from [item, account, source] in query, where: source.provider in ^providers
      end

    account_ids = Enum.map(filters["account_ids"], &String.to_integer/1)

    if account_ids == [] do
      query
    else
      from [item, account, source] in query, where: account.id in ^account_ids
    end
  end

  defp apply_taxonomy_filters(query, filters) do
    Enum.reduce(["genre_ids", "theme_ids", "game_modes"], query, fn key, current ->
      filters[key]
      |> taxonomy_id_groups()
      |> Enum.reduce(current, &require_term_group/2)
    end)
  end

  defp apply_tag_filters(query, []), do: query

  defp apply_tag_filters(query, tag_ids) do
    tag_ids
    |> tag_id_groups()
    |> Enum.reduce(query, &require_term_group/2)
  end

  defp require_term_group(term_ids, query) do
    matching_game_ids =
      from game_term in "game_terms",
        where: field(game_term, :taxonomy_term_id) in ^term_ids,
        select: field(game_term, :game_id)

    from [source: source] in query,
      where: source.game_id in subquery(matching_game_ids)
  end

  defp apply_compatibility_filters(query, filters, owned_source_ids) do
    query
    |> filter_by_source_values(owned_source_ids, :controller_support, filters["controllers"])
    |> filter_by_deck_quality(owned_source_ids, filters["deck"])
    |> filter_by_platforms(owned_source_ids, filters["platforms"])
    |> filter_by_vr(owned_source_ids, "vr" in filters["game_modes"])
  end

  defp filter_by_deck_quality(query, _owned_source_ids, []), do: query

  defp filter_by_deck_quality(query, owned_source_ids, qualities) do
    dynamic =
      Enum.reduce(qualities, dynamic(false), fn
        "ideal", expression ->
          dynamic(
            [source],
            ^expression or source.deck_compatibility == "verified" or
              source.protondb_tier in ["platinum", "gold"]
          )

        "playable", expression ->
          dynamic(
            [source],
            ^expression or source.deck_compatibility == "playable" or
              source.protondb_tier in ["silver", "bronze"]
          )
      end)

    matching_sources =
      from source in GameSource,
        where: source.id in subquery(owned_source_ids),
        where: ^dynamic,
        select: source.id

    filter_by_matching_sources(query, matching_sources)
  end

  defp filter_by_source_values(query, _owned_source_ids, _field, []), do: query

  defp filter_by_source_values(query, owned_source_ids, field, values) do
    matching_sources =
      from source in GameSource,
        where: source.id in subquery(owned_source_ids) and field(source, ^field) in ^values,
        select: source.id

    filter_by_matching_sources(query, matching_sources)
  end

  defp filter_by_platforms(query, _owned_source_ids, []), do: query

  defp filter_by_platforms(query, owned_source_ids, platforms) do
    dynamic =
      Enum.reduce(platforms, dynamic(false), fn
        "windows", expression -> dynamic([source], ^expression or source.available_windows)
        "mac", expression -> dynamic([source], ^expression or source.available_mac)
        "linux", expression -> dynamic([source], ^expression or source.available_linux)
      end)

    matching_sources =
      from source in GameSource,
        where: source.id in subquery(owned_source_ids),
        where: ^dynamic,
        select: source.id

    filter_by_matching_sources(query, matching_sources)
  end

  defp filter_by_vr(query, _owned_source_ids, false), do: query

  defp filter_by_vr(query, owned_source_ids, true) do
    matching_sources =
      from source in GameSource,
        where:
          source.id in subquery(owned_source_ids) and
            source.vr_support in ["supported", "required"],
        select: source.id

    filter_by_matching_sources(query, matching_sources)
  end

  defp filter_by_matching_sources(query, matching_sources) do
    matching_game_ids =
      from source in GameSource,
        where: source.id in subquery(matching_sources) and not is_nil(source.game_id),
        select: source.game_id

    from [source: source] in query,
      where:
        source.id in subquery(matching_sources) or
          source.game_id in subquery(matching_game_ids)
  end

  defp apply_state_filters(query, %{"states" => []}, _user_id), do: query

  defp apply_state_filters(query, %{"states" => states}, user_id) do
    selected_states = Enum.reject(states, &(&1 == "not_played"))
    include_not_played? = "not_played" in states

    matching_game_ids =
      from state in UserGameState,
        where: state.user_id == ^user_id and state.state in ^selected_states,
        select: state.game_id

    classified_game_ids =
      from state in UserGameState,
        where:
          state.user_id == ^user_id and
            state.state in ["backlog", "playing", "completed", "dropped"],
        select: state.game_id

    cond do
      include_not_played? and selected_states == [] ->
        from [source: source] in query,
          where:
            is_nil(source.game_id) or
              source.game_id not in subquery(classified_game_ids)

      include_not_played? ->
        from [source: source] in query,
          where:
            source.game_id in subquery(matching_game_ids) or is_nil(source.game_id) or
              source.game_id not in subquery(classified_game_ids)

      true ->
        from [source: source] in query,
          where: source.game_id in subquery(matching_game_ids)
    end
  end

  defp normalize_filter_params(params) do
    requested_sort = Map.get(params, "sort", "title")

    %{
      "q" => params |> Map.get("q", "") |> text_value() |> String.trim(),
      "providers" => params |> plural_or_legacy("providers", "provider") |> normalize_providers(),
      "account_ids" => params |> plural_or_legacy("account_ids", "account_id") |> normalize_ids(),
      "genre_ids" => params |> plural_or_legacy("genre_ids", "genre_id") |> normalize_ids(),
      "theme_ids" => params |> plural_or_legacy("theme_ids", "theme_id") |> normalize_ids(),
      "tag_ids" => params |> Map.get("tag_ids", []) |> normalize_ids(),
      "game_modes" => normalize_game_modes(params),
      "states" => params |> Map.get("states", []) |> normalize_states(),
      "controllers" => params |> Map.get("controllers", []) |> normalize_controllers(),
      "deck" => params |> Map.get("deck", []) |> normalize_deck(),
      "platforms" => params |> Map.get("platforms", []) |> normalize_platforms(),
      "sort" => normalize_sort(requested_sort),
      "direction" => normalize_direction(Map.get(params, "direction"), requested_sort)
    }
  end

  defp plural_or_legacy(params, plural, legacy) do
    case Map.fetch(params, plural) do
      {:ok, values} -> values
      :error -> Map.get(params, legacy, [])
    end
  end

  defp normalize_providers(values) do
    values
    |> list_value()
    |> Enum.filter(&(&1 in ["steam", "gog"]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_ids(values) do
    values
    |> list_value()
    |> Enum.map(&Params.positive_integer/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&Integer.to_string/1)
  end

  defp normalize_states(values) do
    values
    |> list_value()
    |> Enum.filter(&(&1 in ["backlog", "playing", "completed", "dropped", "not_played"]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_game_modes(params) do
    params
    |> plural_or_legacy("game_modes", "game_mode_ids")
    |> list_value()
    |> Enum.filter(fn value -> value == "vr" or not is_nil(Params.positive_integer(value)) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_controllers(values) do
    values |> list_value() |> Enum.filter(&(&1 in ["full", "partial"])) |> Enum.uniq()
  end

  defp normalize_deck(values) do
    values |> list_value() |> Enum.filter(&(&1 in ["ideal", "playable"])) |> Enum.uniq()
  end

  defp normalize_platforms(values) do
    values |> list_value() |> Enum.filter(&(&1 in ["windows", "mac", "linux"])) |> Enum.uniq()
  end

  defp normalize_sort("rating_desc"), do: "rating"
  defp normalize_sort("my_rating_desc"), do: "my_rating"
  defp normalize_sort("release_year"), do: "release_date"

  defp normalize_sort(value)
       when value in ["title", "rating", "my_rating", "playtime", "release_date"],
       do: value

  defp normalize_sort(_value), do: "title"

  defp normalize_direction(value, _sort) when value in ["asc", "desc"], do: value
  defp normalize_direction(nil, sort) when sort in ["rating_desc", "my_rating_desc"], do: "desc"
  defp normalize_direction(_value, _sort), do: "asc"

  defp list_value(values) when is_list(values), do: values
  defp list_value(value) when is_binary(value), do: [value]
  defp list_value(_value), do: []

  defp taxonomy_id_groups(values) do
    selected_ids =
      values
      |> Enum.map(&Params.positive_integer/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if selected_ids == [], do: [], else: taxonomy_id_groups_for(selected_ids)
  end

  defp taxonomy_id_groups_for(selected_ids) do
    selected_keys =
      Repo.all(from term in TaxonomyTerm, where: term.id in ^selected_ids)
      |> Enum.map(&{TaxonomyTerm.presentation_kind(&1), TaxonomyTerm.normalized_name(&1)})
      |> Enum.uniq()

    terms_by_key =
      Repo.all(TaxonomyTerm)
      |> Enum.group_by(
        &{TaxonomyTerm.presentation_kind(&1), TaxonomyTerm.normalized_name(&1)},
        fn term -> term.id end
      )

    selected_keys
    |> Enum.map(fn key -> terms_by_key |> Map.get(key, []) |> Enum.sort() end)
    |> Enum.reject(&(&1 == []))
  end

  defp tag_id_groups(values) do
    selected_ids =
      values
      |> Enum.map(&Params.positive_integer/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if selected_ids == [], do: [], else: tag_id_groups_for(selected_ids)
  end

  defp tag_id_groups_for(selected_ids) do
    selected_names =
      Repo.all(
        from term in TaxonomyTerm,
          where: term.id in ^selected_ids and term.kind in @tag_kinds
      )
      |> Enum.map(&TaxonomyTerm.normalized_name/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    tag_terms = Repo.all(from term in TaxonomyTerm, where: term.kind in @tag_kinds)

    Enum.map(selected_names, fn selected_name ->
      tag_terms
      |> Enum.filter(&(TaxonomyTerm.normalized_name(&1) == selected_name))
      |> Enum.map(& &1.id)
      |> Enum.sort()
    end)
  end

  defp canonical_tag_terms(terms) do
    groups = Enum.group_by(terms, &TaxonomyTerm.normalized_name/1)

    terms
    |> Enum.map(&TaxonomyTerm.normalized_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.map(fn normalized_name ->
      preferred =
        groups
        |> Map.fetch!(normalized_name)
        |> Enum.max_by(fn term ->
          {tag_kind_priority(term.kind), tag_source_priority(term.source), -term.id}
        end)

      %{preferred | name: TaxonomyTerm.display_name(preferred)}
    end)
  end

  defp tag_kind_priority("player_perspective"), do: 2
  defp tag_kind_priority("keyword"), do: 1
  defp tag_kind_priority(_kind), do: 0

  defp tag_source_priority("igdb"), do: 2
  defp tag_source_priority("vndb"), do: 1
  defp tag_source_priority(_source), do: 0

  defp text_value(value) when is_binary(value), do: value
  defp text_value(_value), do: ""

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp apply_search(query, ""), do: query

  defp apply_search(query, search) do
    fts_query = search |> String.split() |> Enum.map_join(" AND ", &"#{&1}*")

    matching_source_ids =
      from search_index in "library_search",
        where: fragment("library_search MATCH ?", ^fts_query),
        select: type(field(search_index, :source_id), :integer)

    matching_game_ids =
      from matched_source in GameSource,
        where:
          matched_source.id in subquery(matching_source_ids) and
            not is_nil(matched_source.game_id),
        select: matched_source.game_id

    from [source: source] in query,
      where:
        source.id in subquery(matching_source_ids) or
          source.game_id in subquery(matching_game_ids)
  end

  # Playtime sorting uses the viewer's own accounts only, so a shared library's
  # owner sees their own hours ranked, never another user's.
  defp with_personal_playtime(query, user) do
    personal_account_filter = Playtime.personal_account_filter(user)

    personal_source_playtime =
      from item in LibraryItem,
        join: account in ProviderAccount,
        as: :account,
        on: account.id == item.provider_account_id,
        where: ^personal_account_filter,
        where: account.enabled and not item.hidden and is_nil(item.removed_at),
        group_by: item.game_source_id,
        select: %{
          source_id: item.game_source_id,
          minutes: max(item.playtime_minutes)
        }

    personal_game_playtime =
      from item in LibraryItem,
        join: playtime_source in GameSource,
        on: playtime_source.id == item.game_source_id,
        join: account in ProviderAccount,
        as: :account,
        on: account.id == item.provider_account_id,
        where: ^personal_account_filter,
        where:
          account.enabled and not item.hidden and is_nil(item.removed_at) and
            not is_nil(playtime_source.game_id),
        group_by: playtime_source.game_id,
        select: %{
          game_id: playtime_source.game_id,
          minutes: max(item.playtime_minutes)
        }

    from [source: source] in query,
      left_join: game_playtime in subquery(personal_game_playtime),
      as: :game_playtime,
      on: game_playtime.game_id == source.game_id,
      left_join: source_playtime in subquery(personal_source_playtime),
      as: :source_playtime,
      on: source_playtime.source_id == source.id
  end

  defp apply_sort(query, "rating", "desc") do
    from [source: source, game: game] in query,
      order_by: [
        asc: is_nil(game.rating),
        desc: game.rating,
        asc: fragment("COALESCE(?, ?)", game.normalized_title, source.normalized_source_title),
        asc: source.id
      ]
  end

  defp apply_sort(query, "rating", _asc) do
    from [source: source, game: game] in query,
      order_by: [
        asc: is_nil(game.rating),
        asc: game.rating,
        asc: fragment("COALESCE(?, ?)", game.normalized_title, source.normalized_source_title),
        asc: source.id
      ]
  end

  defp apply_sort(query, "my_rating", "desc") do
    from [source: source, game: game, user_state: user_state] in query,
      order_by: [
        asc: is_nil(user_state.rating),
        desc: user_state.rating,
        asc: fragment("COALESCE(?, ?)", game.normalized_title, source.normalized_source_title),
        asc: source.id
      ]
  end

  defp apply_sort(query, "my_rating", _asc) do
    from [source: source, game: game, user_state: user_state] in query,
      order_by: [
        asc: is_nil(user_state.rating),
        asc: user_state.rating,
        asc: fragment("COALESCE(?, ?)", game.normalized_title, source.normalized_source_title),
        asc: source.id
      ]
  end

  defp apply_sort(query, "playtime", "desc") do
    from [
           source: source,
           game: game,
           game_playtime: game_playtime,
           source_playtime: source_playtime
         ] in query,
         order_by: [
           desc: fragment("COALESCE(?, ?, 0)", game_playtime.minutes, source_playtime.minutes),
           asc: fragment("COALESCE(?, ?)", game.normalized_title, source.normalized_source_title),
           asc: source.id
         ]
  end

  defp apply_sort(query, "playtime", _asc) do
    from [
           source: source,
           game: game,
           game_playtime: game_playtime,
           source_playtime: source_playtime
         ] in query,
         order_by: [
           asc: fragment("COALESCE(?, ?, 0)", game_playtime.minutes, source_playtime.minutes),
           asc: fragment("COALESCE(?, ?)", game.normalized_title, source.normalized_source_title),
           asc: source.id
         ]
  end

  defp apply_sort(query, "release_date", "desc") do
    from [source: source, game: game] in query,
      order_by: [
        asc: is_nil(game.release_date),
        desc: game.release_date,
        asc: fragment("COALESCE(?, ?)", game.normalized_title, source.normalized_source_title),
        asc: source.id
      ]
  end

  defp apply_sort(query, "release_date", _asc) do
    from [source: source, game: game] in query,
      order_by: [
        asc: is_nil(game.release_date),
        asc: game.release_date,
        asc: fragment("COALESCE(?, ?)", game.normalized_title, source.normalized_source_title),
        asc: source.id
      ]
  end

  defp apply_sort(query, _title, "desc") do
    from [source: source, game: game] in query,
      order_by: [
        desc: fragment("COALESCE(?, ?)", game.normalized_title, source.normalized_source_title),
        desc: source.id
      ]
  end

  defp apply_sort(query, _title, _asc) do
    from [source: source, game: game] in query,
      order_by: [
        asc: fragment("COALESCE(?, ?)", game.normalized_title, source.normalized_source_title),
        asc: source.id
      ]
  end
end
