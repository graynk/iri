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

defmodule IriWeb.CollectionLive.Form do
  @moduledoc "Authenticated collection creation and metadata-editing form."

  use IriWeb, :live_view

  alias Iri.Collections
  alias Iri.Collections.Collection

  @impl true
  def mount(_params, _session, socket) do
    changeset = Collections.change_collection(socket.assigns.current_scope, %Collection{})

    {:ok,
     socket
     |> assign(:page_title, "Create collection")
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("validate", %{"collection" => params}, socket) do
    changeset =
      socket.assigns.current_scope
      |> Collections.change_collection(%Collection{}, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"collection" => params}, socket) do
    case Collections.create_collection(socket.assigns.current_scope, params) do
      {:ok, collection} ->
        {:noreply,
         socket
         |> put_flash(:info, "Collection created. Add some games.")
         |> push_navigate(to: ~p"/collections/#{collection.id}/edit")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not create the collection.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto w-full max-w-xl">
        <.link
          navigate={~p"/collections"}
          class="inline-flex items-center gap-2 text-sm text-slate-400 transition hover:text-heading"
        >
          <.icon name="hero-arrow-left" class="size-4" /> Collections
        </.link>

        <section class="mt-6 rounded-2xl border border-slate-800 bg-slate-900/45 p-5 sm:p-7">
          <p class="text-xs font-semibold uppercase tracking-[0.24em] text-teal-100">
            New list
          </p>
          <h1 class="mt-2 text-3xl font-semibold tracking-tight text-heading">Create collection</h1>

          <.form
            for={@form}
            id="collection-form"
            phx-change="validate"
            phx-submit="save"
            class="mt-7 space-y-5"
          >
            <.input
              field={@form[:name]}
              id="collection-name"
              type="text"
              label="Name"
              maxlength="80"
              autocomplete="off"
              placeholder="Favorite RPGs"
              autofocus
            />
            <div class="flex flex-wrap justify-end gap-3">
              <.link
                navigate={~p"/collections"}
                class="inline-flex min-h-11 items-center rounded-xl px-4 py-2 text-sm font-semibold text-slate-400 transition hover:bg-slate-800 hover:text-heading"
              >
                Cancel
              </.link>
              <button
                id="create-collection"
                type="submit"
                phx-disable-with="Creating…"
                class="inline-flex min-h-11 items-center rounded-xl bg-teal-300 px-4 py-2 text-sm font-semibold text-on-accent transition hover:bg-teal-200"
              >
                Create
              </button>
            </div>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
