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

defmodule IriWeb.Settings.EpicImportLive do
  @moduledoc "Authenticated upload and preview flow for Legendary Epic library exports."

  use IriWeb, :live_view

  alias Iri.Integrations.LibraryReconciler
  alias Iri.Integrations.Epic.LegendaryParser
  alias Iri.Sync.Scheduler

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Import Epic Games")
     |> assign(:preview, nil)
     |> assign(:form, to_form(%{"label" => "Epic Games"}, as: :epic))
     |> allow_upload(:legendary, accept: ~w(.json), max_entries: 1, max_file_size: 20_000_000)}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("preview", %{"epic" => params}, socket) do
    results =
      consume_uploaded_entries(socket, :legendary, fn %{path: path}, _entry ->
        case File.read(path) do
          {:ok, body} -> {:ok, LegendaryParser.parse(body)}
          error -> {:ok, error}
        end
      end)

    case results do
      [{:ok, entries}] ->
        {:noreply,
         socket
         |> assign(:preview, %{
           entries: entries,
           label: String.trim(params["label"] || "Epic Games")
         })
         |> assign(:form, to_form(params, as: :epic))}

      [{:error, reason}] ->
        {:noreply, put_flash(socket, :error, parser_message(reason))}

      _ ->
        {:noreply, put_flash(socket, :error, "Choose a Legendary JSON export first.")}
    end
  end

  def handle_event("import", _params, %{assigns: %{preview: preview}} = socket)
      when not is_nil(preview) do
    attrs = %{
      external_user_id: "legendary:#{socket.assigns.current_scope.user.id}",
      display_name: preview.label
    }

    case LibraryReconciler.import(socket.assigns.current_scope, :epic, attrs, preview.entries,
           complete: true
         ) do
      {:ok, result} ->
        if result.counts.inserted_count > 0, do: Scheduler.enqueue_library_enrichment()

        {:noreply,
         socket
         |> assign(:preview, nil)
         |> put_flash(:info, "Imported #{result.counts.discovered_count} Epic games.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, inspect_reason(reason))}
    end
  end

  def handle_event("import", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Preview an export first.")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto w-full max-w-3xl space-y-6">
        <header class="border-b border-slate-800 pb-6">
          <.link
            navigate={~p"/settings/integrations"}
            class="text-sm text-teal-300 hover:text-teal-200"
          >← Integrations</.link><h1 class="mt-3 text-3xl font-semibold text-heading">
            Import Epic Games
          </h1><p class="mt-2 text-sm text-slate-400">
            Install <a
              id="legendary-installation"
              href="https://github.com/legendary-gl/legendary"
              target="_blank"
              rel="noreferrer"
              class="font-medium text-sky-300 underline decoration-sky-300/50 underline-offset-2 transition hover:text-sky-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-sky-300"
            >Legendary</a>, authenticate it outside IRI, then run <code class="rounded bg-slate-900 px-1.5 py-1">legendary list --json</code>, save its output, and upload it here. IRI does not run Legendary or keep Epic credentials.
          </p>
        </header>
        <section class="rounded-3xl border border-slate-800 bg-slate-950/60 p-6">
          <.form
            for={@form}
            id="legendary-upload-form"
            phx-change="validate"
            phx-submit="preview"
            class="space-y-4"
          >
            <.input field={@form[:label]} label="Library label" />
            <.live_file_input
              upload={@uploads.legendary}
              class="block w-full rounded-2xl border border-dashed border-slate-700 p-6 text-sm text-slate-300"
            />
            <p :for={error <- upload_errors(@uploads.legendary)} class="text-sm text-rose-300">
              {Phoenix.Naming.humanize(error)}
            </p>
            <.button id="preview-legendary">Preview export</.button>
          </.form>
        </section>
        <section
          :if={@preview}
          id="legendary-preview"
          class="rounded-3xl border border-teal-400/25 bg-teal-400/5 p-6"
        >
          <h2 class="font-semibold text-heading">{length(@preview.entries)} base games found</h2>
          <p class="mt-1 text-sm text-slate-400">
            DLC entries are excluded. Importing another complete export later will reconcile removals.
          </p>
          <button
            id="confirm-legendary-import"
            phx-click="import"
            class="mt-5 rounded-xl bg-teal-300 px-5 py-2.5 font-semibold text-on-accent hover:bg-teal-200"
          >Import library</button>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp parser_message(:invalid_json), do: "That file is not valid JSON."
  defp parser_message(:file_too_large), do: "The export is larger than 20 MB."
  defp parser_message(_), do: "That is not a supported Legendary export."

  defp inspect_reason(reason),
    do: reason |> Iri.Security.Redactor.redact_inspect() |> String.slice(0, 300)
end
