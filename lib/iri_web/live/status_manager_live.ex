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

defmodule IriWeb.StatusManagerLive do
  @moduledoc "Authenticated bulk editor for completion state and personal rating."

  use IriWeb, :live_view

  import IriWeb.StatusManagerLive.Presentation

  alias Iri.Library.{Personalization, StatusManager}
  alias Iri.Params

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Manage completion statuses")
     |> assign(:filters, default_filters())
     |> assign(:filters_form, to_form(default_filters(), as: :filters))
     |> assign(:query_signature, nil)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:viewed_ids, MapSet.new())
     |> assign(:selection_anchor, nil)
     |> assign(:selection_notice, nil)
     |> assign(:page_ids, [])
     |> assign(:total_count, 0)
     |> assign(:page, 1)
     |> assign(:page_count, 1)
     |> stream_configure(:status_games, dom_id: &"status-game-#{&1.id}")
     |> stream(:status_games, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:ok, page} =
      StatusManager.list_games(socket.assigns.current_scope, params,
        exclude_ids: MapSet.to_list(socket.assigns.viewed_ids)
      )

    signature = query_signature(page.filters)

    query_changed? =
      not is_nil(socket.assigns.query_signature) and socket.assigns.query_signature != signature

    selection_notice =
      if query_changed? and MapSet.size(socket.assigns.selected_ids) > 0,
        do: "Selection cleared because the search or sort changed.",
        else: nil

    selected_ids = if query_changed?, do: MapSet.new(), else: socket.assigns.selected_ids
    anchor = if query_changed?, do: nil, else: socket.assigns.selection_anchor

    {:noreply,
     socket
     |> assign(:selected_ids, selected_ids)
     |> assign(:selection_anchor, anchor)
     |> assign(:selection_notice, selection_notice)
     |> assign(:query_signature, signature)
     |> assign_page(page)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    params = Map.put_new(params, "direction", socket.assigns.filters["direction"])
    {:noreply, push_patch(socket, to: ~p"/library/statuses?#{filter_query(params, 1)}")}
  end

  def handle_event("toggle_sort_direction", _params, socket) do
    direction = if socket.assigns.filters["direction"] == "asc", do: "desc", else: "asc"
    params = Map.put(socket.assigns.filters, "direction", direction)

    {:noreply, push_patch(socket, to: ~p"/library/statuses?#{filter_query(params, 1)}")}
  end

  def handle_event("toggle_selection", %{"id" => id, "selected" => selected}, socket) do
    with {:ok, game_id} <- parse_id(id),
         true <- game_id in socket.assigns.page_ids do
      selected_ids = update_selection(socket.assigns.selected_ids, [game_id], selected?(selected))

      {:noreply,
       socket
       |> assign(:selected_ids, selected_ids)
       |> assign(:selection_anchor, game_id)
       |> assign(:selection_notice, nil)
       |> restream_games([game_id])}
    else
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("select_range", %{"id" => id, "selected" => selected}, socket) do
    with {:ok, game_id} <- parse_id(id),
         true <- game_id in socket.assigns.page_ids do
      range_ids =
        selection_range(socket.assigns.page_ids, socket.assigns.selection_anchor, game_id)

      selected_ids = update_selection(socket.assigns.selected_ids, range_ids, selected?(selected))

      {:noreply,
       socket
       |> assign(:selected_ids, selected_ids)
       |> assign(:selection_anchor, game_id)
       |> assign(:selection_notice, nil)
       |> restream_games(range_ids)}
    else
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("toggle_page_selection", %{"selected" => selected}, socket) do
    selected_ids =
      update_selection(socket.assigns.selected_ids, socket.assigns.page_ids, selected?(selected))

    {:noreply,
     socket
     |> assign(:selected_ids, selected_ids)
     |> assign(:selection_anchor, List.last(socket.assigns.page_ids))
     |> assign(:selection_notice, nil)
     |> restream_games(socket.assigns.page_ids)}
  end

  def handle_event("clear_selection", _params, socket) do
    visible_selected_ids =
      Enum.filter(socket.assigns.page_ids, &MapSet.member?(socket.assigns.selected_ids, &1))

    {:noreply,
     socket
     |> assign(:selected_ids, MapSet.new())
     |> assign(:selection_anchor, nil)
     |> assign(:selection_notice, nil)
     |> restream_games(visible_selected_ids)}
  end

  def handle_event("mark_viewed", _params, socket) do
    if MapSet.size(socket.assigns.selected_ids) == 0 do
      {:noreply, socket}
    else
      viewed_ids = MapSet.union(socket.assigns.viewed_ids, socket.assigns.selected_ids)

      {:ok, page} =
        StatusManager.list_games(
          socket.assigns.current_scope,
          Map.put(socket.assigns.filters, "page", socket.assigns.page),
          exclude_ids: MapSet.to_list(viewed_ids)
        )

      updated_socket =
        socket
        |> assign(:viewed_ids, viewed_ids)
        |> assign(:selected_ids, MapSet.new())
        |> assign(:selection_anchor, nil)
        |> assign(:selection_notice, nil)
        |> assign_page(page)
        |> push_viewed_store(viewed_ids)

      page_reply(updated_socket, socket.assigns.page, page)
    end
  end

  def handle_event("restore_viewed", _params, socket) do
    {:ok, page} =
      StatusManager.list_games(
        socket.assigns.current_scope,
        Map.put(socket.assigns.filters, "page", socket.assigns.page)
      )

    updated_socket =
      socket
      |> assign(:viewed_ids, MapSet.new())
      |> assign(:selection_notice, nil)
      |> assign_page(page)
      |> push_viewed_store(MapSet.new())

    page_reply(updated_socket, socket.assigns.page, page)
  end

  # Restores the viewed set the browser remembered in localStorage.
  def handle_event("sync_viewed", %{"ids" => ids}, socket) do
    viewed_ids =
      ids
      |> List.wrap()
      |> Enum.flat_map(fn value ->
        case parse_id(value) do
          {:ok, id} -> [id]
          _error -> []
        end
      end)
      |> MapSet.new()

    if MapSet.equal?(viewed_ids, socket.assigns.viewed_ids) do
      {:noreply, socket}
    else
      {:ok, page} =
        StatusManager.list_games(
          socket.assigns.current_scope,
          Map.put(socket.assigns.filters, "page", socket.assigns.page),
          exclude_ids: MapSet.to_list(viewed_ids)
        )

      {:noreply, socket |> assign(:viewed_ids, viewed_ids) |> assign_page(page)}
    end
  end

  def handle_event("sync_viewed", _params, socket), do: {:noreply, socket}

  def handle_event("apply_status", %{"state" => state}, socket)
      when state in ["backlog", "playing", "completed", "dropped", "not_played"] do
    game_ids = MapSet.to_list(socket.assigns.selected_ids)
    stored_state = if state == "not_played", do: nil, else: state

    case Personalization.batch_set_completion_state(
           socket.assigns.current_scope,
           game_ids,
           stored_state
         ) do
      {:ok, count} ->
        {:ok, page} =
          StatusManager.list_games(
            socket.assigns.current_scope,
            Map.put(socket.assigns.filters, "page", socket.assigns.page),
            exclude_ids: MapSet.to_list(socket.assigns.viewed_ids)
          )

        message = "#{count} #{pluralize(count, "game", "games")} marked #{status_label(state)}."

        updated_socket =
          socket
          |> assign(:selected_ids, MapSet.new())
          |> assign(:selection_anchor, nil)
          |> assign(:selection_notice, nil)
          |> assign_page(page)
          |> put_flash(:info, message)

        if page.page != socket.assigns.page do
          {:noreply,
           push_patch(updated_socket,
             to: ~p"/library/statuses?#{filter_query(page.filters, page.page)}"
           )}
        else
          {:noreply, updated_socket}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update the selected games.")}
    end
  end

  def handle_event("apply_status", _params, socket), do: {:noreply, socket}

  def handle_event(
        "set_rating",
        %{"id" => id, "rating" => rating, "active" => active},
        socket
      ) do
    with {:ok, game_id} <- parse_id(id),
         true <- game_id in socket.assigns.page_ids,
         {:ok, rating} <- parse_rating(rating),
         {:ok, _game_state} <-
           Personalization.set_rating(
             socket.assigns.current_scope,
             game_id,
             if(selected?(active), do: nil, else: rating)
           ) do
      # Rating a game also selects it, so a status can be applied in one go.
      {:noreply,
       socket
       |> update(:selected_ids, &MapSet.put(&1, game_id))
       |> assign(:selection_anchor, game_id)
       |> restream_games([game_id])}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not save that rating.")}
    end
  end

  def handle_event("set_rating", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} jump_to_top={false}>
      <div
        id="status-manager"
        phx-hook="StatusViewedStore"
        class="mx-auto w-full max-w-5xl space-y-6"
      >
        <header class="space-y-4 border-b border-slate-800 pb-6">
          <.link
            id="status-back-to-library"
            navigate={~p"/library"}
            phx-hook="LibraryLink"
            class="inline-flex items-center gap-2 text-sm text-slate-400 transition hover:text-heading"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to library
          </.link>

          <div class="flex flex-wrap items-end justify-between gap-3">
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.24em] text-teal-300">
                Bulk editing
              </p>
              <h1 class="mt-2 text-3xl font-semibold tracking-tight text-heading sm:text-4xl">
                Manage completion statuses
              </h1>
              <p class="mt-2 text-sm text-slate-400">
                {@total_count} {pluralize(@total_count, "game", "games")}
              </p>
            </div>
            <p id="selection-summary" aria-live="polite" class="min-h-5 text-sm text-teal-200">
              {MapSet.size(@selected_ids)} selected
            </p>
          </div>

          <p id="selection-notice" aria-live="polite" class="text-sm text-amber-200">
            {@selection_notice}
          </p>

          <.form for={@filters_form} id="status-filter-form" phx-change="filter">
            <div class="space-y-3 sm:grid sm:grid-cols-2 sm:gap-3 sm:space-y-0 lg:grid-cols-[minmax(0,1fr)_12rem_15rem]">
              <div class="sm:col-span-2 lg:col-span-1">
                <.search_input
                  field={@filters_form[:q]}
                  id="status-search"
                  label="Search"
                  placeholder="Search games…"
                  autocomplete="off"
                  phx-debounce="250"
                />
              </div>
              <.input
                field={@filters_form[:status]}
                id="status-filter"
                type="select"
                label="Status"
                options={[
                  {"All", "all"},
                  {"Playing", "playing"},
                  {"Want to play", "backlog"},
                  {"Completed", "completed"},
                  {"Dropped", "dropped"},
                  {"Not played", "not_played"}
                ]}
              />
              <.sort_input
                field={@filters_form[:sort]}
                id="status-sort"
                label="Sort by"
                direction={@filters["direction"]}
                options={[
                  {"Title", "title"},
                  {"Release date", "release_date"},
                  {"Playtime", "playtime"}
                ]}
              />
            </div>
          </.form>
        </header>

        <div class="overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/35">
          <div class="flex min-h-12 items-center justify-between gap-3 border-b border-slate-800 bg-slate-900/80 px-3 sm:px-4">
            <label
              for="status-select-page"
              class="flex min-h-11 cursor-pointer items-center gap-3 text-sm font-medium text-slate-300"
            >
              <input
                id="status-select-page"
                type="checkbox"
                checked={page_fully_selected?(@page_ids, @selected_ids)}
                phx-click="toggle_page_selection"
                phx-value-selected={to_string(!page_fully_selected?(@page_ids, @selected_ids))}
                class="size-4 rounded border-slate-600 bg-slate-900 text-teal-300 focus:ring-teal-300"
              /> Select this page
            </label>
            <div class="flex items-center gap-3">
              <span class="hidden text-xs text-slate-500 sm:inline">Up to 100 games per page</span>
              <button
                :if={MapSet.size(@viewed_ids) > 0}
                id="restore-viewed-games"
                type="button"
                phx-click="restore_viewed"
                class="inline-flex min-h-9 items-center gap-1.5 rounded-lg px-2.5 text-xs font-semibold text-teal-100 transition hover:bg-teal-400/10"
              >
                <.icon name="hero-arrow-path" class="size-3.5" />
                Show {MapSet.size(@viewed_ids)} viewed
              </button>
            </div>
          </div>

          <ul id="status-games" phx-update="stream" class="divide-y divide-slate-800">
            <li
              id="status-games-empty"
              class="hidden px-6 py-16 text-center text-sm text-slate-500 only:block"
            >
              {if MapSet.size(@viewed_ids) > 0,
                do: "No games left in this view.",
                else: "No games match this search."}
            </li>

            <li
              :for={{id, game} <- @streams.status_games}
              id={id}
              data-game-id={game.id}
              data-selected={to_string(MapSet.member?(@selected_ids, game.id))}
              phx-hook="StatusSelection"
              class={[
                "grid min-h-20 cursor-pointer select-none grid-cols-[2.75rem_3rem_minmax(0,1fr)] items-center gap-3 px-3 py-3 transition sm:grid-cols-[2.75rem_3rem_minmax(0,1fr)_5rem_5rem_7rem] sm:px-4",
                if(MapSet.member?(@selected_ids, game.id),
                  do: "bg-teal-400/10 ring-1 ring-inset ring-teal-400/25",
                  else: "hover:bg-slate-800/45"
                )
              ]}
            >
              <div class="grid size-11 place-items-center rounded-lg hover:bg-slate-800">
                <input
                  id={"status-select-#{game.id}"}
                  type="checkbox"
                  data-status-selection-checkbox
                  checked={MapSet.member?(@selected_ids, game.id)}
                  aria-label={"Select #{game.title}"}
                  class="size-4 rounded border-slate-600 bg-slate-900 text-teal-300 focus:ring-teal-300"
                />
              </div>

              <div class="aspect-[3/4] overflow-hidden rounded-md bg-slate-800">
                <img
                  :if={cover_asset(game)}
                  src={~p"/media/#{cover_asset(game).id}"}
                  alt=""
                  loading="lazy"
                  class="size-full object-cover"
                />
                <span
                  :if={!cover_asset(game)}
                  class="grid size-full place-items-center text-lg font-bold text-slate-500"
                >
                  {game.title |> String.first() |> String.upcase()}
                </span>
              </div>

              <div class="min-w-0">
                <.link
                  id={"status-game-link-#{game.id}"}
                  navigate={~p"/games/#{game.slug}"}
                  data-status-selection-ignore
                  class="inline-block max-w-full truncate align-bottom text-sm font-semibold text-slate-100 transition hover:text-teal-100 hover:underline focus-visible:text-teal-100"
                >
                  {game.title}
                </.link>
                <p class="mt-1 text-xs text-slate-500 sm:hidden">
                  {release_year(game)} · {playtime_label(game)} · {status_label(personal_state(game))}
                </p>
                <div
                  id={"status-rating-#{game.id}"}
                  class="mt-2 flex items-center gap-0.5"
                  role="group"
                  aria-label={"Personal rating for #{game.title}"}
                >
                  <button
                    :for={rating <- 1..5}
                    id={"status-rate-#{game.id}-#{rating}"}
                    type="button"
                    data-status-selection-ignore
                    phx-click="set_rating"
                    phx-value-id={game.id}
                    phx-value-rating={rating}
                    phx-value-active={to_string(personal_rating(game) == rating)}
                    aria-label={rating_action_label(game, rating)}
                    aria-pressed={to_string(selected_rating_face?(game, rating))}
                    title={rating_action_label(game, rating)}
                    class={status_rating_class(selected_rating_face?(game, rating), rating)}
                  >
                    <.rating_face rating={rating_face_value(game, rating)} class="size-4" />
                  </button>
                  <button
                    :if={is_number(personal_rating(game)) and personal_rating(game) > 1}
                    id={"status-half-rating-#{game.id}"}
                    type="button"
                    data-status-selection-ignore
                    phx-click="set_rating"
                    phx-value-id={game.id}
                    phx-value-rating={format_rating_value(half_toggle_value(game))}
                    phx-value-active="false"
                    aria-label={half_toggle_label(game)}
                    aria-pressed={to_string(half_rating?(personal_rating(game)))}
                    title={half_toggle_label(game)}
                    class={[
                      "ml-1 grid size-7 place-items-center rounded-md border text-[0.65rem] font-bold transition focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-teal-300",
                      half_rating?(personal_rating(game)) &&
                        "border-violet-400/50 bg-violet-400/15 text-violet-200",
                      !half_rating?(personal_rating(game)) &&
                        "border-slate-700 text-slate-500 hover:border-slate-600 hover:text-slate-300"
                    ]}
                  >
                    ½
                  </button>
                </div>
              </div>

              <span class="hidden text-sm text-slate-400 sm:block">{release_year(game)}</span>
              <span
                id={"status-playtime-#{game.id}"}
                class="hidden items-center gap-1 text-sm tabular-nums text-slate-400 sm:flex"
                title="Your playtime"
              >
                <span class="sr-only">Your playtime:</span>
                <.icon name="hero-clock" class="size-3.5 text-slate-600" /> {playtime_label(game)}
              </span>
              <span class={status_badge(personal_state(game))}>
                {status_label(personal_state(game))}
              </span>
            </li>
          </ul>
        </div>

        <nav
          :if={@page_count > 1}
          id="status-pagination"
          aria-label="Status manager pages"
          class="flex items-center justify-center gap-4"
        >
          <.link
            :if={@page > 1}
            id="status-previous-page"
            patch={~p"/library/statuses?#{filter_query(@filters, @page - 1)}"}
            class="inline-flex min-h-11 items-center gap-1 rounded-xl border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-300 transition hover:bg-slate-800"
          >
            <.icon name="hero-chevron-left" class="size-4" /> Previous
          </.link>
          <span class="text-sm text-slate-400">Page {@page} of {@page_count}</span>
          <.link
            :if={@page < @page_count}
            id="status-next-page"
            patch={~p"/library/statuses?#{filter_query(@filters, @page + 1)}"}
            class="inline-flex min-h-11 items-center gap-1 rounded-xl border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-300 transition hover:bg-slate-800"
          >
            Next <.icon name="hero-chevron-right" class="size-4" />
          </.link>
        </nav>

        <div
          id="batch-status-actions"
          class="sticky bottom-3 z-30 rounded-2xl border border-slate-700 bg-slate-900/95 p-3 pb-[calc(0.75rem+env(safe-area-inset-bottom))] shadow-2xl shadow-black/40 backdrop-blur sm:flex sm:items-center sm:justify-between sm:gap-4"
        >
          <p class="mb-3 min-w-24 text-sm font-semibold text-heading sm:mb-0">
            {MapSet.size(@selected_ids)} selected
          </p>
          <div class="grid grid-cols-3 gap-1.5 sm:flex sm:flex-wrap sm:justify-end sm:gap-2">
            <button
              id="batch-mark-playing"
              type="button"
              phx-click="apply_status"
              phx-value-state="playing"
              phx-disable-with="Updating…"
              disabled={MapSet.size(@selected_ids) == 0}
              class="inline-flex min-h-11 items-center justify-center gap-1.5 rounded-xl bg-sky-400/15 px-2 py-2 text-xs font-semibold sm:px-3 sm:text-sm text-sky-200 ring-1 ring-sky-400/30 transition hover:bg-sky-400/25 disabled:cursor-not-allowed disabled:opacity-40"
            >
              <.icon name="hero-play-circle" class="size-4" /> Playing
            </button>
            <button
              id="batch-mark-want-to-play"
              type="button"
              phx-click="apply_status"
              phx-value-state="backlog"
              phx-disable-with="Updating…"
              disabled={MapSet.size(@selected_ids) == 0}
              class="inline-flex min-h-11 items-center justify-center gap-1.5 rounded-xl bg-violet-400/15 px-2 py-2 text-xs font-semibold sm:px-3 sm:text-sm text-violet-200 ring-1 ring-violet-400/30 transition hover:bg-violet-400/25 disabled:cursor-not-allowed disabled:opacity-40"
            >
              <.icon name="hero-bookmark" class="size-4" /> Want to play
            </button>
            <button
              id="batch-mark-completed"
              type="button"
              phx-click="apply_status"
              phx-value-state="completed"
              phx-disable-with="Updating…"
              disabled={MapSet.size(@selected_ids) == 0}
              class="inline-flex min-h-11 items-center justify-center gap-1.5 rounded-xl bg-emerald-400/15 px-2 py-2 text-xs font-semibold sm:px-3 sm:text-sm text-emerald-200 ring-1 ring-emerald-400/30 transition hover:bg-emerald-400/25 disabled:cursor-not-allowed disabled:opacity-40"
            >
              <.icon name="hero-check-circle" class="size-4" /> Completed
            </button>
            <button
              id="batch-mark-dropped"
              type="button"
              phx-click="apply_status"
              phx-value-state="dropped"
              phx-disable-with="Updating…"
              disabled={MapSet.size(@selected_ids) == 0}
              class="inline-flex min-h-11 items-center justify-center gap-1.5 rounded-xl bg-rose-400/15 px-2 py-2 text-xs font-semibold sm:px-3 sm:text-sm text-rose-200 ring-1 ring-rose-400/30 transition hover:bg-rose-400/25 disabled:cursor-not-allowed disabled:opacity-40"
            >
              <.icon name="hero-no-symbol" class="size-4" /> Dropped
            </button>
            <button
              id="batch-mark-not-played"
              type="button"
              phx-click="apply_status"
              phx-value-state="not_played"
              phx-disable-with="Updating…"
              disabled={MapSet.size(@selected_ids) == 0}
              class="inline-flex min-h-11 items-center justify-center rounded-xl border border-slate-600 px-2 py-2 text-xs font-semibold sm:px-3 sm:text-sm text-slate-300 transition hover:bg-slate-800 disabled:cursor-not-allowed disabled:opacity-40"
            >
              Not played
            </button>
            <button
              id="batch-mark-viewed"
              type="button"
              phx-click="mark_viewed"
              disabled={MapSet.size(@selected_ids) == 0}
              title="Temporarily hide the selected games from this list so you can work through the rest. They stay in your library and come back when you clear viewed."
              class="inline-flex min-h-11 items-center justify-center gap-1.5 rounded-xl border border-teal-400/30 px-2 py-2 text-xs font-semibold sm:px-3 sm:text-sm text-teal-100 transition hover:bg-teal-400/10 disabled:cursor-not-allowed disabled:opacity-40"
            >
              <.icon name="hero-eye-slash" class="size-4" /> Mark viewed
            </button>
            <button
              id="clear-status-selection"
              type="button"
              phx-click="clear_selection"
              disabled={MapSet.size(@selected_ids) == 0}
              class="inline-flex min-h-11 items-center justify-center rounded-xl px-2 py-2 text-xs font-semibold sm:px-3 sm:text-sm text-slate-400 transition hover:bg-slate-800 hover:text-heading disabled:cursor-not-allowed disabled:opacity-40"
            >
              Clear selection
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp assign_page(socket, page) do
    socket
    |> assign(:filters, page.filters)
    |> assign(
      :filters_form,
      to_form(Map.take(page.filters, ["q", "status", "sort", "direction"]), as: :filters)
    )
    |> assign(:total_count, page.total_count)
    |> assign(:page, page.page)
    |> assign(:page_count, page.page_count)
    |> assign(:page_ids, Enum.map(page.entries, & &1.id))
    |> stream(:status_games, page.entries, reset: true)
  end

  defp push_viewed_store(socket, viewed_ids) do
    push_event(socket, "status:viewed-store", %{ids: MapSet.to_list(viewed_ids)})
  end

  defp restream_games(socket, []), do: socket

  defp restream_games(socket, game_ids) do
    case StatusManager.list_games_by_ids(socket.assigns.current_scope, game_ids) do
      {:ok, games} -> Enum.reduce(games, socket, &stream_insert(&2, :status_games, &1))
      {:error, _reason} -> socket
    end
  end

  defp update_selection(selected_ids, game_ids, true) do
    Enum.reduce(game_ids, selected_ids, &MapSet.put(&2, &1))
  end

  defp update_selection(selected_ids, game_ids, false) do
    Enum.reduce(game_ids, selected_ids, &MapSet.delete(&2, &1))
  end

  defp selection_range(_page_ids, nil, game_id), do: [game_id]

  defp selection_range(page_ids, anchor, game_id) do
    with anchor_index when is_integer(anchor_index) <- Enum.find_index(page_ids, &(&1 == anchor)),
         game_index when is_integer(game_index) <- Enum.find_index(page_ids, &(&1 == game_id)) do
      first = min(anchor_index, game_index)
      count = abs(anchor_index - game_index) + 1
      Enum.slice(page_ids, first, count)
    else
      _missing -> [game_id]
    end
  end

  defp page_fully_selected?([], _selected_ids), do: false

  defp page_fully_selected?(page_ids, selected_ids) do
    Enum.all?(page_ids, &MapSet.member?(selected_ids, &1))
  end

  defp selected?(value), do: value in [true, "true", "on", "1"]

  defp parse_id(value) do
    case Params.positive_integer(value) do
      nil -> {:error, :invalid_id}
      id -> {:ok, id}
    end
  end

  defp parse_rating(value) when is_number(value) do
    if value >= 1 and value <= 5 and value * 2 == round(value * 2),
      do: {:ok, value / 1},
      else: {:error, :invalid_rating}
  end

  defp parse_rating(value) when is_binary(value) do
    case Float.parse(value) do
      {rating, ""} when rating >= 1 and rating <= 5 ->
        parse_rating(rating)

      _other ->
        {:error, :invalid_rating}
    end
  end

  defp parse_rating(_value), do: {:error, :invalid_rating}

  defp query_signature(filters),
    do: {filters["q"], filters["status"], filters["sort"], filters["direction"]}

  defp default_filters,
    do: %{
      "q" => "",
      "status" => "all",
      "sort" => "title",
      "direction" => "asc",
      "page" => 1
    }

  defp filter_query(params, page) do
    filters = %{
      "q" => params |> Map.get("q", "") |> text_value() |> String.trim(),
      "status" => params |> Map.get("status", "all") |> text_value(),
      "sort" => params |> Map.get("sort", "title") |> text_value(),
      "direction" => params |> Map.get("direction", "asc") |> text_value()
    }

    %{}
    |> maybe_put("q", filters["q"], "")
    |> maybe_put("status", filters["status"], "all")
    |> maybe_put("sort", filters["sort"], "title")
    |> maybe_put("direction", filters["direction"], "asc")
    |> maybe_put("page", page, 1)
  end

  defp maybe_put(query, _key, value, value), do: query
  defp maybe_put(query, key, value, _default), do: Map.put(query, key, value)

  defp text_value(value) when is_binary(value), do: value
  defp text_value(_value), do: ""

  defp page_reply(socket, previous_page, page) do
    if page.page != previous_page do
      {:noreply,
       push_patch(socket, to: ~p"/library/statuses?#{filter_query(page.filters, page.page)}")}
    else
      {:noreply, socket}
    end
  end
end
