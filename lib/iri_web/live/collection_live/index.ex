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

defmodule IriWeb.CollectionLive.Index do
  @moduledoc "Authenticated index of the viewer's collections and Family-mode shared collections."

  use IriWeb, :live_view

  alias Iri.Collections
  alias Iri.InstancePolicy

  @impl true
  def mount(_params, _session, socket) do
    collections = Collections.list_collections(socket.assigns.current_scope)

    family_collections =
      Collections.list_family_public_collections(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Collections")
     |> assign(:collections_empty?, collections == [])
     |> assign(:family_mode?, InstancePolicy.family?())
     |> stream_configure(:collections, dom_id: &"collection-#{&1.collection.id}")
     |> stream(:collections, collections)
     |> stream_configure(:family_collections,
       dom_id: &"family-collection-#{&1.collection.id}"
     )
     |> stream(:family_collections, family_collections)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="collections-index" class="mx-auto w-full max-w-6xl space-y-7">
        <header class="flex flex-wrap items-end justify-between gap-4 border-b border-slate-800 pb-6">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.24em] text-teal-100">
              Personal lists
            </p>
            <h1 class="mt-2 text-4xl font-semibold tracking-tight text-heading">Collections</h1>
            <p class="mt-2 text-sm text-slate-400">
              Group the games you want to remember, recommend, or revisit.
            </p>
          </div>
          <.button
            :if={!@demo?}
            id="new-collection"
            navigate={~p"/collections/new"}
            class="gap-2"
          >
            <.icon name="hero-plus" class="size-4" /> Create collection
          </.button>
        </header>

        <section aria-labelledby="your-collections-heading">
          <h2 id="your-collections-heading" class="sr-only">Your collections</h2>
          <div
            id="collections"
            phx-update="stream"
            class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3"
          >
            <div
              id="collections-empty"
              class="hidden rounded-2xl border border-dashed border-slate-700 bg-slate-900/30 px-6 py-16 text-center sm:col-span-2 lg:col-span-3 only:block"
            >
              <.icon name="hero-bookmark-square" class="mx-auto size-8 text-slate-600" />
              <p class="mt-4 text-sm text-slate-400">
                Collections give selected games a useful home without changing your library.
              </p>
              <.link
                :if={!@demo?}
                navigate={~p"/collections/new"}
                class="mt-5 inline-flex min-h-11 items-center rounded-xl border border-teal-400/50 px-4 py-2 text-sm font-semibold text-teal-100 transition hover:bg-teal-400/10"
              >
                Create your first collection
              </.link>
            </div>

            <.collection_card
              :for={{id, row} <- @streams.collections}
              id={id}
              row={row}
              variant={:owner}
              demo?={@demo?}
            />
          </div>
        </section>

        <section
          :if={@family_mode?}
          id="family-public-collections"
          class="space-y-4 border-t border-slate-800 pt-7"
        >
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.24em] text-teal-300">
              Family library
            </p>
            <h2 class="mt-2 text-2xl font-semibold tracking-tight text-heading">
              Public family collections
            </h2>
            <p class="mt-1 text-sm text-slate-400">
              Collections that other family members have chosen to share.
            </p>
          </div>

          <div
            id="family-collections"
            phx-update="stream"
            class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3"
          >
            <div
              id="family-collections-empty"
              class="hidden rounded-2xl border border-dashed border-slate-700 bg-slate-900/30 px-6 py-12 text-center text-sm text-slate-500 sm:col-span-2 lg:col-span-3 only:block"
            >
              No public collections have been shared by your family yet.
            </div>

            <.collection_card
              :for={{id, row} <- @streams.family_collections}
              id={id}
              row={row}
              variant={:family}
              demo?={@demo?}
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true
  attr :variant, :atom, required: true, values: [:owner, :family]
  attr :demo?, :boolean, required: true

  defp collection_card(assigns) do
    assigns = assign(assigns, :collection_path, collection_path(assigns.row, assigns.variant))

    ~H"""
    <article
      id={@id}
      data-gamepad-card
      data-gamepad-selected="false"
      class="relative overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/45 transition hover:border-slate-700 hover:bg-slate-900/70"
    >
      <div data-collection-cover class="block">
        <div class="grid h-32 grid-cols-4 gap-0.5 bg-slate-950">
          <div
            :if={@row.cover_ids == []}
            class="col-span-4 grid place-items-center text-slate-700"
          >
            <.icon name="hero-photo" class="size-8" />
          </div>
          <img
            :for={cover_id <- @row.cover_ids}
            src={~p"/media/#{cover_id}"}
            alt=""
            loading="lazy"
            class="h-32 w-full object-cover"
          />
        </div>
      </div>
      <div class="space-y-4 p-4">
        <div>
          <div class="flex items-start justify-between gap-3">
            <h3 class="line-clamp-2 min-w-0 break-words font-semibold text-heading">
              {@row.collection.name}
            </h3>
            <span
              :if={@variant == :family || @row.collection.sharing_enabled}
              class="shrink-0 rounded-full bg-teal-400/10 px-2 py-1 text-[0.65rem] font-semibold text-teal-100 ring-1 ring-teal-400/20"
            >
              {if @variant == :family, do: "Family public", else: "Shared by link"}
            </span>
          </div>
          <p :if={@variant == :family} class="mt-1 text-xs font-medium text-teal-300">
            By {@row.owner_name}
          </p>
          <p class="mt-1 text-sm text-slate-400">
            {@row.accessible_game_count} {pluralize(
              @row.accessible_game_count,
              "game",
              "games"
            )}
            <span class="text-slate-700">·</span>
            Updated {date_label(@row.collection.updated_at)}
          </p>
        </div>
        <div class="flex gap-2">
          <.link
            id={
              if(@variant == :family,
                do: "open-family-collection-#{@row.collection.id}",
                else: "open-collection-#{@row.collection.id}"
              )
            }
            navigate={@collection_path}
            data-gamepad-item
            aria-label={"Open #{@row.collection.name}"}
            class="inline-flex min-h-10 flex-1 items-center justify-center rounded-lg border border-slate-700 text-sm font-semibold text-slate-200 transition after:absolute after:inset-0 hover:bg-slate-800"
          >
            Open
          </.link>
          <.link
            :if={@variant == :owner && !@demo?}
            id={"edit-collection-#{@row.collection.id}"}
            navigate={~p"/collections/#{@row.collection.id}/edit"}
            aria-label={"Edit #{@row.collection.name}"}
            class="relative z-10 inline-flex min-h-10 flex-1 items-center justify-center rounded-lg border border-slate-700 text-sm font-semibold text-slate-300 transition hover:bg-slate-800"
          >
            Edit
          </.link>
        </div>
      </div>
    </article>
    """
  end

  defp collection_path(%{collection: collection}, :owner),
    do: ~p"/collections/#{collection.id}"

  defp collection_path(%{share_token: share_token}, :family),
    do: ~p"/collections/shared?#{%{share_token: share_token}}"

  defp date_label(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%d %b %Y")
  defp date_label(_datetime), do: "recently"
  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural
end
