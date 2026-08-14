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

defmodule IriWeb.CollectionLive.Edit do
  @moduledoc "Authenticated collection editor for membership, ordering, comments, sharing, and exports."

  use IriWeb, :live_view

  alias Iri.Collections
  alias Iri.Params

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Collections.list_collection_games(socket.assigns.current_scope, id) do
      {:ok, collection, entries} ->
        name_form =
          socket.assigns.current_scope
          |> Collections.change_collection(collection)
          |> to_form()

        {:ok,
         socket
         |> assign(:page_title, "Edit #{collection.name}")
         |> assign(:collection, collection)
         |> assign(:name_form, name_form)
         |> assign(:search_form, to_form(%{"q" => ""}, as: :search))
         |> assign(:search_query, "")
         |> assign(:search_empty?, true)
         |> assign(:selected_game_ids, MapSet.new())
         |> assign(:game_count, length(entries))
         |> assign(:collection_message, nil)
         |> assign(:order_message, nil)
         |> assign(:share_message, nil)
         |> assign(:delete_form, to_form(%{"name" => ""}, as: :delete))
         |> assign(:delete_error, nil)
         |> stream_configure(:collection_games, dom_id: &"collection-edit-game-#{&1.id}")
         |> stream_configure(:search_results, dom_id: &"collection-search-game-#{&1.id}")
         |> stream(:collection_games, annotate_positions(entries))
         |> stream(:search_results, [])
         |> assign_sharing(collection)}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Collection not found.")
         |> push_navigate(to: ~p"/collections")}
    end
  end

  @impl true
  def handle_event("validate_name", %{"collection" => params}, socket) do
    changeset =
      socket.assigns.current_scope
      |> Collections.change_collection(socket.assigns.collection, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :name_form, to_form(changeset))}
  end

  def handle_event("save_name", %{"collection" => params}, socket) do
    case Collections.update_collection(
           socket.assigns.current_scope,
           socket.assigns.collection.id,
           params
         ) do
      {:ok, collection} ->
        {:noreply,
         socket
         |> assign(:collection, collection)
         |> assign(:page_title, "Edit #{collection.name}")
         |> assign(
           :name_form,
           to_form(Collections.change_collection(socket.assigns.current_scope, collection))
         )
         |> assign(:collection_message, "Name saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :name_form, to_form(changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not rename the collection.")}
    end
  end

  def handle_event("search", %{"search" => %{"q" => query}}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, String.trim(query))
     |> assign(:search_form, to_form(%{"q" => query}, as: :search))
     |> refresh_search()}
  end

  def handle_event("toggle_search_game", %{"id" => id}, socket) do
    with {:ok, game_id} <- parse_id(id) do
      selected_game_ids =
        if MapSet.member?(socket.assigns.selected_game_ids, game_id) do
          MapSet.delete(socket.assigns.selected_game_ids, game_id)
        else
          MapSet.put(socket.assigns.selected_game_ids, game_id)
        end

      {:noreply,
       socket
       |> assign(:selected_game_ids, selected_game_ids)
       |> refresh_search()}
    else
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("add_selected", _params, socket) do
    game_ids = MapSet.to_list(socket.assigns.selected_game_ids)

    case Collections.add_games(
           socket.assigns.current_scope,
           socket.assigns.collection.id,
           game_ids
         ) do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign(:selected_game_ids, MapSet.new())
         |> assign(:collection_message, "Added #{count} #{pluralize(count, "game", "games")}.")
         |> reload_collection()
         |> refresh_search()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not add the selected games.")}
    end
  end

  def handle_event("remove_game", %{"id" => game_id}, socket) do
    case Collections.remove_game(
           socket.assigns.current_scope,
           socket.assigns.collection.id,
           game_id
         ) do
      {:ok, :ok} ->
        {:noreply,
         socket
         |> assign(:collection_message, "Game removed.")
         |> reload_collection()
         |> refresh_search()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove that game.")}
    end
  end

  def handle_event(
        "save_entry_comment",
        %{"collection_entry" => %{"game_id" => game_id, "comment" => comment}},
        socket
      ) do
    save_entry_comment(socket, game_id, comment)
  end

  def handle_event(
        "save_entry_comment",
        %{"id" => game_id, "value" => comment},
        socket
      ) do
    save_entry_comment(socket, game_id, comment)
  end

  def handle_event("save_entry_comment", _params, socket), do: {:noreply, socket}

  def handle_event("reorder_game", params, socket) do
    with {:ok, moved_game_id} <- parse_id(Map.get(params, "moved_id")),
         {:ok, before_game_id} <- parse_optional_id(Map.get(params, "before_id")),
         {:ok, :ok} <-
           Collections.move_game(
             socket.assigns.current_scope,
             socket.assigns.collection.id,
             moved_game_id,
             before_game_id
           ) do
      {:reply, %{ok: true}, order_saved(socket)}
    else
      _error ->
        {:reply, %{ok: false}, put_flash(socket, :error, "Could not reorder that game.")}
    end
  end

  def handle_event("move_game_up", %{"id" => game_id}, socket) do
    move_game_with(socket, game_id, &Collections.move_game_up/3)
  end

  def handle_event("move_game_down", %{"id" => game_id}, socket) do
    move_game_with(socket, game_id, &Collections.move_game_down/3)
  end

  def handle_event("enable_sharing", _params, socket) do
    update_sharing(socket, &Collections.enable_sharing/2, "Link sharing enabled.")
  end

  def handle_event("disable_sharing", _params, socket) do
    update_sharing(socket, &Collections.disable_sharing/2, "Link sharing stopped.")
  end

  def handle_event("regenerate_share_link", _params, socket) do
    update_sharing(socket, &Collections.regenerate_share_link/2, "A new share link is ready.")
  end

  def handle_event("share_link_copied", _params, socket) do
    {:noreply, assign(socket, :share_message, "Link copied.")}
  end

  def handle_event("delete_collection", %{"delete" => %{"name" => confirmation}}, socket) do
    if String.trim(confirmation) == socket.assigns.collection.name do
      case Collections.delete_collection(
             socket.assigns.current_scope,
             socket.assigns.collection.id
           ) do
        {:ok, _collection} ->
          {:noreply, push_navigate(socket, to: ~p"/collections")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not delete the collection.")}
      end
    else
      {:noreply,
       socket
       |> assign(:delete_form, to_form(%{"name" => confirmation}, as: :delete))
       |> assign(:delete_error, "Enter the collection name exactly to confirm.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="collection-edit" class="mx-auto w-full max-w-7xl space-y-7">
        <header class="flex flex-wrap items-end justify-between gap-4 border-b border-slate-800 pb-6">
          <div>
            <.link
              navigate={~p"/collections"}
              class="inline-flex items-center gap-2 text-sm text-slate-400 transition hover:text-heading"
            >
              <.icon name="hero-arrow-left" class="size-4" /> Collections
            </.link>
            <h1 class="mt-4 text-3xl font-semibold tracking-tight text-heading">
              Edit “{@collection.name}”
            </h1>
          </div>
          <.link
            id="view-collection"
            navigate={~p"/collections/#{@collection.id}"}
            class="inline-flex min-h-11 items-center rounded-xl border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-200 transition hover:bg-slate-800"
          >
            View collection
          </.link>
        </header>

        <div class="grid gap-5 lg:grid-cols-2">
          <section class="rounded-2xl border border-slate-800 bg-slate-900/40 p-4 sm:p-5">
            <h2 class="font-semibold text-heading">Collection name</h2>
            <.form
              for={@name_form}
              id="collection-name-form"
              phx-change="validate_name"
              phx-submit="save_name"
              class="mt-4 flex items-start gap-3"
            >
              <div class="min-w-0 flex-1">
                <.input
                  field={@name_form[:name]}
                  id="edit-collection-name"
                  type="text"
                  label="Name"
                  maxlength="80"
                />
              </div>
              <button
                id="save-collection-name"
                type="submit"
                phx-disable-with="Saving…"
                class="mt-7 inline-flex min-h-11 items-center rounded-xl border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-200 transition hover:bg-slate-800"
              >
                Save
              </button>
            </.form>
            <p id="collection-feedback" aria-live="polite" class="mt-3 text-sm text-teal-300">
              {@collection_message}
            </p>
          </section>

          <section
            id="collection-sharing"
            class="rounded-2xl border border-slate-800 bg-slate-900/40 p-4 sm:p-5"
          >
            <div class="flex items-center justify-between gap-3">
              <div>
                <h2 class="font-semibold text-heading">Sharing</h2>
                <p class="mt-1 text-sm text-slate-400">
                  {if @collection.sharing_enabled, do: "Shared by link", else: "Private"}
                </p>
              </div>
              <button
                :if={!@collection.sharing_enabled}
                id="enable-collection-sharing"
                type="button"
                phx-click="enable_sharing"
                phx-disable-with="Enabling…"
                class="inline-flex min-h-11 items-center rounded-xl border border-teal-400/50 px-4 py-2 text-sm font-semibold text-teal-100 transition hover:bg-teal-400/10"
              >
                Enable link sharing
              </button>
            </div>

            <div :if={@collection.sharing_enabled} class="mt-4 space-y-3">
              <.input
                name="collection_share_url"
                id="collection-share-url"
                type="text"
                label="Read-only link"
                value={@share_url}
                readonly
              />
              <div class="flex flex-wrap gap-2">
                <button
                  id="copy-collection-share-url"
                  type="button"
                  phx-hook="CopyToClipboard"
                  data-copy-source="#collection-share-url"
                  class="inline-flex min-h-11 items-center gap-2 rounded-xl border border-slate-700 px-3 py-2 text-sm font-semibold text-slate-200 transition hover:bg-slate-800"
                >
                  <.icon name="hero-clipboard" class="size-4" /> Copy link
                </button>
                <button
                  id="regenerate-collection-share-url"
                  type="button"
                  phx-click="regenerate_share_link"
                  data-confirm="Generate a new link? Every old copy will stop working."
                  class="inline-flex min-h-11 items-center rounded-xl px-3 py-2 text-sm font-semibold text-slate-400 transition hover:bg-slate-800 hover:text-heading"
                >
                  Regenerate
                </button>
                <button
                  id="disable-collection-sharing"
                  type="button"
                  phx-click="disable_sharing"
                  data-confirm="Stop sharing? Every current copy of the link will stop working."
                  class="inline-flex min-h-11 items-center rounded-xl px-3 py-2 text-sm font-semibold text-rose-300 transition hover:bg-rose-400/10"
                >
                  Stop sharing
                </button>
              </div>
            </div>
            <p id="collection-share-feedback" aria-live="polite" class="mt-3 text-sm text-teal-100">
              {@share_message}
            </p>
          </section>
        </div>

        <div class="grid items-start gap-6 lg:grid-cols-2">
          <section class="rounded-2xl border border-slate-800 bg-slate-900/35 p-4 sm:p-5">
            <div class="flex items-end justify-between gap-3">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.2em] text-teal-300">
                  Search library
                </p>
                <h2 class="mt-1 font-semibold text-heading">Add games</h2>
              </div>
              <span class="text-sm text-teal-100">{MapSet.size(@selected_game_ids)} selected</span>
            </div>

            <.form for={@search_form} id="collection-search-form" phx-change="search" class="mt-4">
              <.search_input
                field={@search_form[:q]}
                id="collection-search"
                label="Search games"
                placeholder="Title or store title…"
                autocomplete="off"
                phx-debounce="250"
                autofocus
              />
            </.form>

            <div
              id="collection-search-results"
              phx-update="stream"
              class="mt-4 max-h-[34rem] divide-y divide-slate-800 overflow-y-auto rounded-xl border border-slate-800"
            >
              <p
                id="collection-search-empty"
                class="hidden px-4 py-10 text-center text-sm text-slate-500 only:block"
              >
                {if @search_query == "",
                  do: "Type a title to search your library.",
                  else: "No matching games."}
              </p>
              <label
                :for={{id, game} <- @streams.search_results}
                id={id}
                class={[
                  "grid min-h-16 grid-cols-[2.75rem_minmax(0,1fr)_auto] items-center gap-3 px-3 py-2",
                  game.added && "cursor-not-allowed opacity-55",
                  !game.added && "cursor-pointer hover:bg-slate-800/45"
                ]}
              >
                <div class="aspect-[3/4] overflow-hidden rounded bg-slate-800">
                  <img
                    :if={game.cover_id}
                    src={~p"/media/#{game.cover_id}"}
                    alt=""
                    loading="lazy"
                    class="size-full object-cover"
                  />
                </div>
                <div class="min-w-0">
                  <p class="truncate text-sm font-semibold text-slate-100">{game.title}</p>
                  <p class="text-xs text-slate-500">{year(game.release_year)}</p>
                </div>
                <span :if={game.added} class="text-xs font-semibold text-slate-500">Added</span>
                <input
                  :if={!game.added}
                  id={"select-collection-game-#{game.id}"}
                  type="checkbox"
                  checked={MapSet.member?(@selected_game_ids, game.id)}
                  phx-click="toggle_search_game"
                  phx-value-id={game.id}
                  aria-label={"Select #{game.title}"}
                  class="size-4 rounded border-slate-600 bg-slate-900 text-teal-300 focus:ring-teal-300"
                />
              </label>
            </div>

            <button
              id="add-selected-games"
              type="button"
              phx-click="add_selected"
              phx-disable-with="Adding…"
              disabled={MapSet.size(@selected_game_ids) == 0}
              class="mt-4 inline-flex min-h-11 w-full items-center justify-center rounded-xl bg-teal-300 px-4 py-2 text-sm font-semibold text-on-accent transition hover:bg-teal-200 disabled:cursor-not-allowed disabled:opacity-40"
            >
              Add {MapSet.size(@selected_game_ids)} selected
            </button>
          </section>

          <section class="rounded-2xl border border-slate-800 bg-slate-900/35 p-4 sm:p-5">
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-teal-300">
              In this collection
            </p>
            <div class="mt-1 flex items-baseline justify-between gap-3">
              <h2 class="font-semibold text-heading">Custom order</h2>
              <span class="text-sm text-slate-400">{@game_count} {pluralize(
                @game_count,
                "game",
                "games"
              )}</span>
            </div>
            <p class="mt-2 text-xs text-slate-500">
              Drag by the handle or use the arrow buttons. This order is used when the collection is sorted by Custom order.
            </p>
            <p id="collection-order-feedback" aria-live="polite" class="mt-2 text-sm text-teal-300">
              {@order_message}
            </p>

            <div
              id="collection-current-games"
              phx-hook="CollectionReorder"
              phx-update="stream"
              aria-busy="false"
              class="mt-4 divide-y divide-slate-800 overflow-hidden rounded-xl border border-slate-800"
            >
              <p
                id="collection-current-games-empty"
                class="hidden px-4 py-12 text-center text-sm text-slate-500 only:block"
              >
                No games added yet.
              </p>
              <div
                :for={{id, entry} <- @streams.collection_games}
                id={id}
                data-reorder-row
                data-game-id={entry.game_id}
                class="grid grid-cols-[2.25rem_2.25rem_minmax(0,1fr)_auto] items-start gap-2 px-2.5 py-2 transition-colors"
              >
                <button
                  type="button"
                  data-reorder-handle
                  aria-label={"Drag #{entry.title} to reorder"}
                  title="Drag to reorder"
                  class="grid size-9 touch-none cursor-grab place-items-center rounded-lg text-slate-500 transition hover:bg-slate-800 hover:text-slate-200 active:cursor-grabbing"
                >
                  <.icon name="hero-bars-3" class="size-5" />
                </button>
                <div class="aspect-[3/4] overflow-hidden rounded bg-slate-800">
                  <img
                    :if={entry.cover_id}
                    src={~p"/media/#{entry.cover_id}"}
                    alt=""
                    loading="lazy"
                    class="size-full object-cover"
                  />
                </div>
                <div class="min-w-0">
                  <div class="flex min-w-0 items-baseline gap-2">
                    <p class="truncate text-sm font-semibold text-slate-100">{entry.title}</p>
                    <p class="shrink-0 text-xs text-slate-500">{year(entry.release_year)}</p>
                  </div>
                  <.form
                    for={entry.comment_form}
                    id={"collection-entry-comment-form-#{entry.game_id}"}
                    phx-submit="save_entry_comment"
                    class="mt-1 min-w-0"
                  >
                    <.input
                      field={entry.comment_form[:game_id]}
                      id={"collection-entry-game-id-#{entry.game_id}"}
                      type="hidden"
                    />
                    <div class="min-w-0 flex-1">
                      <.input
                        field={entry.comment_form[:comment]}
                        id={"collection-entry-comment-#{entry.game_id}"}
                        type="text"
                        maxlength="300"
                        placeholder="Collection comment (optional)"
                        aria-label={"Comment for #{entry.title}"}
                        phx-blur="save_entry_comment"
                        phx-value-id={entry.game_id}
                        class="h-8 min-h-8 w-full rounded-lg border border-slate-700 bg-slate-950/70 px-2.5 py-1 text-xs text-slate-200 outline-none transition placeholder:text-slate-600 focus:border-teal-300 focus:ring-2 focus:ring-teal-300/20"
                      />
                    </div>
                  </.form>
                </div>
                <div class="flex items-center gap-0.5">
                  <button
                    id={"move-collection-game-up-#{entry.game_id}"}
                    type="button"
                    phx-click="move_game_up"
                    phx-value-id={entry.game_id}
                    phx-disable-with="…"
                    disabled={entry.first}
                    aria-label={"Move #{entry.title} up"}
                    title="Move up"
                    class="grid size-9 place-items-center rounded-lg text-slate-500 transition hover:bg-slate-800 hover:text-slate-200 disabled:cursor-not-allowed disabled:opacity-25"
                  >
                    <.icon name="hero-chevron-up" class="size-4" />
                  </button>
                  <button
                    id={"move-collection-game-down-#{entry.game_id}"}
                    type="button"
                    phx-click="move_game_down"
                    phx-value-id={entry.game_id}
                    phx-disable-with="…"
                    disabled={entry.last}
                    aria-label={"Move #{entry.title} down"}
                    title="Move down"
                    class="grid size-9 place-items-center rounded-lg text-slate-500 transition hover:bg-slate-800 hover:text-slate-200 disabled:cursor-not-allowed disabled:opacity-25"
                  >
                    <.icon name="hero-chevron-down" class="size-4" />
                  </button>
                  <button
                    id={"remove-collection-game-#{entry.game_id}"}
                    type="button"
                    phx-click="remove_game"
                    phx-value-id={entry.game_id}
                    aria-label={"Remove #{entry.title}"}
                    class="grid size-9 place-items-center rounded-lg text-slate-500 transition hover:bg-rose-400/10 hover:text-rose-300"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>
              </div>
            </div>
          </section>
        </div>

        <section class="rounded-2xl border border-rose-950/70 bg-rose-950/10 p-4 sm:p-5">
          <h2 class="font-semibold text-rose-200">Delete collection</h2>
          <p class="mt-1 text-sm text-slate-400">
            Enter <span class="font-semibold text-slate-200">{@collection.name}</span>
            to confirm. Games and library data are not deleted.
          </p>
          <.form
            for={@delete_form}
            id="delete-collection-form"
            phx-submit="delete_collection"
            class="mt-4 flex flex-wrap items-start gap-3"
          >
            <div class="min-w-64 flex-1">
              <.input
                field={@delete_form[:name]}
                id="delete-collection-name"
                type="text"
                label="Collection name"
                autocomplete="off"
              />
              <p :if={@delete_error} id="delete-collection-error" class="mt-2 text-sm text-rose-300">
                {@delete_error}
              </p>
            </div>
            <button
              id="delete-collection"
              type="submit"
              phx-disable-with="Deleting…"
              class="mt-7 inline-flex min-h-11 items-center rounded-xl border border-rose-500/40 px-4 py-2 text-sm font-semibold text-rose-200 transition hover:bg-rose-400/10"
            >
              Delete permanently
            </button>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp refresh_search(socket) do
    case Collections.search_addable_games(
           socket.assigns.current_scope,
           socket.assigns.collection.id,
           socket.assigns.search_query
         ) do
      {:ok, results} ->
        socket
        |> assign(:search_empty?, results == [])
        |> stream(:search_results, results, reset: true)

      {:error, _reason} ->
        socket
    end
  end

  defp reload_collection(socket) do
    case Collections.list_collection_games(
           socket.assigns.current_scope,
           socket.assigns.collection.id
         ) do
      {:ok, collection, entries} ->
        socket
        |> assign(:collection, collection)
        |> assign(:game_count, length(entries))
        |> stream(:collection_games, annotate_positions(entries), reset: true)
        |> assign_sharing(collection)

      {:error, _reason} ->
        socket
        |> put_flash(:error, "Collection no longer exists.")
        |> push_navigate(to: ~p"/collections")
    end
  end

  defp update_sharing(socket, operation, message) do
    case operation.(socket.assigns.current_scope, socket.assigns.collection.id) do
      {:ok, collection} ->
        {:noreply,
         socket
         |> assign(:collection, collection)
         |> assign(:share_message, message)
         |> assign_sharing(collection)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update collection sharing.")}
    end
  end

  defp assign_sharing(socket, %{sharing_enabled: true} = collection) do
    case Collections.share_token(socket.assigns.current_scope, collection.id) do
      {:ok, token} ->
        assign(socket, :share_url, url(~p"/collections/shared?#{%{share_token: token}}"))

      {:error, _reason} ->
        assign(socket, :share_url, nil)
    end
  end

  defp assign_sharing(socket, _collection), do: assign(socket, :share_url, nil)

  defp parse_id(value) do
    case Params.positive_integer(value) do
      nil -> {:error, :invalid_id}
      id -> {:ok, id}
    end
  end

  defp parse_optional_id(value) when value in [nil, ""], do: {:ok, nil}
  defp parse_optional_id(value), do: parse_id(value)

  defp save_entry_comment(socket, game_id, comment) do
    case Collections.update_entry_comment(
           socket.assigns.current_scope,
           socket.assigns.collection.id,
           game_id,
           comment
         ) do
      {:ok, _entry} ->
        {:noreply, assign(socket, :collection_message, "Comment saved.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Comments can be at most 300 characters.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not save that comment.")}
    end
  end

  defp move_game_with(socket, game_id, operation) do
    case operation.(socket.assigns.current_scope, socket.assigns.collection.id, game_id) do
      {:ok, :ok} -> {:noreply, order_saved(socket)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Could not reorder that game.")}
    end
  end

  defp order_saved(socket) do
    socket
    |> assign(:order_message, "Order saved.")
    |> reload_collection()
  end

  defp annotate_positions(entries) do
    last_index = length(entries) - 1

    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      entry
      |> Map.put(:first, index == 0)
      |> Map.put(:last, index == last_index)
      |> Map.put(
        :comment_form,
        to_form(
          %{"game_id" => Integer.to_string(entry.game_id), "comment" => entry.comment || ""},
          as: :collection_entry
        )
      )
    end)
  end

  defp year(year) when is_integer(year), do: Integer.to_string(year)
  defp year(_year), do: "Unknown year"
  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural
end
