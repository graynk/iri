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

defmodule IriWeb.CollectionLive.Show do
  @moduledoc "Authenticated read-only collection view with sorting and export links."

  use IriWeb, :live_view

  alias Iri.Collections
  alias IriWeb.CollectionLive.Components

  @sort_keys ~w(title release_year igdb_rating my_rating)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:collection_id, id)
     |> assign(:sort, "custom")
     |> assign(:sort_direction, "asc")
     |> assign(:next_cursor, nil)
     |> stream_configure(:collection_games, dom_id: &"collection-game-#{&1.id}")
     |> stream(:collection_games, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case Collections.list_collection_games_page(
           socket.assigns.current_scope,
           socket.assigns.collection_id,
           Map.get(params, "sort"),
           Map.get(params, "direction"),
           nil
         ) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(:page_title, page.collection.name)
         |> assign(:collection, page.collection)
         |> assign(:sort, page.sort)
         |> assign(:sort_direction, page.sort_direction)
         |> assign(:next_cursor, page.next_cursor)
         |> assign(:game_count, page.total_count)
         |> stream(:collection_games, page.entries, reset: true)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Collection not found.")
         |> push_navigate(to: ~p"/collections")}
    end
  end

  @impl true
  def handle_event("sort_collection", %{"sort" => clicked_sort}, socket)
      when clicked_sort in @sort_keys do
    {sort, direction} =
      Components.next_sort(socket.assigns.sort, socket.assigns.sort_direction, clicked_sort)

    {:noreply, push_patch(socket, to: collection_path(socket, sort, direction))}
  end

  def handle_event("load_more", _params, %{assigns: %{next_cursor: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    case Collections.list_collection_games_page(
           socket.assigns.current_scope,
           socket.assigns.collection.id,
           socket.assigns.sort,
           socket.assigns.sort_direction,
           socket.assigns.next_cursor
         ) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(:next_cursor, page.next_cursor)
         |> stream(:collection_games, page.entries)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not load more games.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="collection-show" class="mx-auto w-full max-w-5xl space-y-6">
        <header class="flex flex-wrap items-end justify-between gap-4 border-b border-slate-800 pb-6">
          <div>
            <.link
              navigate={~p"/collections"}
              class="inline-flex items-center gap-2 text-sm text-slate-400 transition hover:text-heading"
            >
              <.icon name="hero-arrow-left" class="size-4" /> Collections
            </.link>
            <h1 class="mt-4 text-3xl font-semibold tracking-tight text-heading sm:text-4xl">
              {@collection.name}
            </h1>
            <p class="mt-2 text-sm text-slate-400">
              {@game_count} {Components.pluralize(@game_count, "game", "games")}
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.link
              id="export-collection-csv"
              href={~p"/collections/#{@collection.id}/export.csv"}
              download
              class="inline-flex min-h-11 items-center gap-2 rounded-xl border border-slate-700 px-3 py-2 text-sm font-semibold text-slate-300 transition hover:bg-slate-800 hover:text-heading"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> CSV
            </.link>
            <.link
              id="export-collection-txt"
              href={~p"/collections/#{@collection.id}/export.txt"}
              download
              class="inline-flex min-h-11 items-center gap-2 rounded-xl border border-slate-700 px-3 py-2 text-sm font-semibold text-slate-300 transition hover:bg-slate-800 hover:text-heading"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> TXT
            </.link>
            <span class="group relative inline-flex">
              <.link
                id="export-collection-html"
                href={~p"/collections/#{@collection.id}/export.zip"}
                download
                aria-describedby="export-collection-html-help"
                class="inline-flex min-h-11 items-center gap-2 rounded-xl border border-slate-700 px-3 py-2 text-sm font-semibold text-slate-300 transition hover:bg-slate-800 hover:text-heading"
              >
                <.icon name="hero-code-bracket" class="size-4" /> HTML
              </.link>
              <span
                id="export-collection-html-help"
                role="tooltip"
                class="pointer-events-none absolute right-0 top-full z-20 mt-2 hidden w-72 rounded-xl border border-slate-700 bg-slate-950 px-3 py-2 text-xs font-normal leading-relaxed text-slate-300 shadow-xl group-hover:block group-focus-within:block"
              >
                Portable static website ZIP that starts with your current theme and includes a theme selector. Multiple exports use the same merge-safe assets folder.
              </span>
            </span>
            <.link
              :if={!@demo?}
              id="edit-collection"
              navigate={~p"/collections/#{@collection.id}/edit"}
              class="inline-flex min-h-11 items-center gap-2 rounded-xl border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-200 transition hover:bg-slate-800"
            >
              <.icon name="hero-pencil-square" class="size-4" /> Edit
            </.link>
          </div>
        </header>

        <Components.collection_listing
          variant={:owner}
          label={"Games in #{@collection.name}"}
          entries={@streams.collection_games}
          sort={@sort}
          sort_direction={@sort_direction}
          next_cursor={@next_cursor}
        />
      </div>
    </Layouts.app>
    """
  end

  defp collection_path(socket, "custom", _direction),
    do: ~p"/collections/#{socket.assigns.collection.id}"

  defp collection_path(socket, sort, direction),
    do: ~p"/collections/#{socket.assigns.collection.id}?#{%{sort: sort, direction: direction}}"
end
