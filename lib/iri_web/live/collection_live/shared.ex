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

defmodule IriWeb.CollectionLive.Shared do
  @moduledoc "Unauthenticated read-only collection capability-link view."

  use IriWeb, :live_view

  alias Iri.Collections
  alias IriWeb.CollectionLive.Components

  @sort_keys ~w(title release_year igdb_rating my_rating)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:sort, "custom")
     |> assign(:sort_direction, "asc")
     |> assign(:next_cursor, nil)
     |> assign(:share_token, nil)
     |> assign(:not_found?, false)
     |> stream_configure(:shared_collection_games,
       dom_id: &"shared-collection-game-#{&1.id}"
     )
     |> stream(:shared_collection_games, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    share_token = Map.get(params, "share_token", "")

    case Collections.get_shared_collection_page(
           socket.assigns.current_scope,
           share_token,
           Map.get(params, "sort"),
           Map.get(params, "direction"),
           nil
         ) do
      {:ok, shared} ->
        {:noreply,
         socket
         |> assign(:page_title, shared.collection.name)
         |> assign(:shared, shared)
         |> assign(:share_token, share_token)
         |> assign(:sort, shared.sort)
         |> assign(:sort_direction, shared.sort_direction)
         |> assign(:next_cursor, shared.next_cursor)
         |> assign(:not_found?, false)
         |> assign(:game_count, shared.total_count)
         |> stream(:shared_collection_games, shared.entries, reset: true)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:page_title, "Collection not found")
         |> assign(:not_found?, true)
         |> stream(:shared_collection_games, [], reset: true)}
    end
  end

  @impl true
  def handle_event("sort_collection", %{"sort" => clicked_sort}, socket)
      when clicked_sort in @sort_keys do
    {sort, direction} =
      Components.next_sort(socket.assigns.sort, socket.assigns.sort_direction, clicked_sort)

    {:noreply, push_patch(socket, to: shared_collection_path(socket, sort, direction))}
  end

  def handle_event("load_more", _params, %{assigns: %{next_cursor: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    case Collections.get_shared_collection_page(
           socket.assigns.current_scope,
           socket.assigns.share_token,
           socket.assigns.sort,
           socket.assigns.sort_direction,
           socket.assigns.next_cursor
         ) do
      {:ok, shared} ->
        {:noreply,
         socket
         |> assign(:next_cursor, shared.next_cursor)
         |> stream(:shared_collection_games, shared.entries)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not load more games.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="shared-collection" class="mx-auto w-full max-w-5xl space-y-6">
        <section
          :if={@not_found?}
          id="shared-collection-not-found"
          class="rounded-2xl border border-slate-800 bg-slate-900/40 px-6 py-16 text-center"
        >
          <.icon name="hero-link-slash" class="mx-auto size-8 text-slate-600" />
          <h1 class="mt-4 text-2xl font-semibold text-heading">Collection not found</h1>
          <p class="mt-2 text-sm text-slate-400">
            This link is invalid, disabled, or no longer available.
          </p>
          <.link
            navigate={~p"/collections"}
            class="mt-5 inline-flex min-h-11 items-center rounded-xl border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-200 transition hover:bg-slate-800"
          >
            My collections
          </.link>
        </section>

        <div :if={!@not_found?} class="space-y-6">
          <header class="flex flex-wrap items-end justify-between gap-4 border-b border-slate-800 pb-6">
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.24em] text-teal-100">
                Shared collection · Read only
              </p>
              <h1 class="mt-2 text-3xl font-semibold tracking-tight text-heading sm:text-4xl">
                {@shared.collection.name}
              </h1>
              <p class="mt-2 text-sm text-slate-400">
                Shared by {@shared.owner_name} · {@game_count} {Components.pluralize(
                  @game_count,
                  "game",
                  "games"
                )}
              </p>
            </div>
            <.link
              :if={@shared.viewer_is_owner}
              navigate={~p"/collections/#{@shared.collection.id}"}
              class="inline-flex min-h-11 items-center rounded-xl border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-200 transition hover:bg-slate-800"
            >
              Open my collection
            </.link>
          </header>

          <Components.collection_listing
            variant={:shared}
            label={"Games in #{@shared.collection.name}"}
            entries={@streams.shared_collection_games}
            sort={@sort}
            sort_direction={@sort_direction}
            next_cursor={@next_cursor}
            owner_name={@shared.owner_name}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp shared_collection_path(socket, "custom", _direction),
    do:
      ~p"/collections/shared?#{%{share_token: socket.assigns.share_token, sort: "custom", direction: "asc"}}"

  defp shared_collection_path(socket, sort, direction),
    do:
      ~p"/collections/shared?#{%{share_token: socket.assigns.share_token, sort: sort, direction: direction}}"
end
