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

defmodule IriWeb.Settings.PSNImportLive do
  @moduledoc "Authenticated import flow for a browser-collected PlayStation library export."

  use IriWeb, :live_view

  alias Iri.Integrations.LibraryReconciler
  alias Iri.Integrations.PSN.Parser
  alias Iri.Sync.Scheduler

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Import PlayStation")
     |> assign(:preview, nil)
     |> assign(:form, to_form(%{}, as: :psn))
     |> allow_upload(:psn_export,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: 20_000_000
     )}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("preview", _params, socket) do
    uploaded =
      consume_uploaded_entries(socket, :psn_export, fn %{path: path}, _entry ->
        {:ok, File.read(path)}
      end)

    case uploaded do
      [{:ok, body}] ->
        case Parser.parse(body) do
          {:ok, preview} ->
            {:noreply, assign(socket, :preview, preview)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, message(reason))}
        end

      _entries ->
        {:noreply, put_flash(socket, :error, "Choose the collector file first.")}
    end
  end

  def handle_event("import", _params, %{assigns: %{preview: preview}} = socket)
      when not is_nil(preview) do
    attrs = %{
      external_user_id: preview.account.id,
      display_name: preview.account.name
    }

    case LibraryReconciler.import(socket.assigns.current_scope, :psn, attrs, preview.entries,
           complete: preview.complete?
         ) do
      {:ok, result} ->
        LibraryReconciler.retire_matching(result.account, &Parser.non_game_source?/1)
        if result.counts.inserted_count > 0, do: Scheduler.enqueue_library_enrichment()

        {:noreply,
         socket
         |> assign(:preview, nil)
         |> put_flash(:info, "Imported #{result.counts.discovered_count} PlayStation games.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Iri.Security.Redactor.redact_inspect(reason))}
    end
  end

  def handle_event("import", _, socket),
    do: {:noreply, put_flash(socket, :error, "Preview a PlayStation file first.")}

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
            Import PlayStation games
          </h1><p class="mt-2 text-sm leading-6 text-slate-400">
            Capture the games shown by PlayStation, then import the downloaded file here. Repeat these steps while signed into each PSN account you use.
          </p>
        </header>
        <details open class="rounded-2xl border border-slate-800 bg-slate-950/60 p-5">
          <summary class="cursor-pointer font-semibold text-slate-100">
            How to collect your games
          </summary>
          <ol class="mt-4 space-y-4 text-sm leading-6 text-slate-300">
            <li class="flex gap-3">
              <span class="grid size-7 shrink-0 place-items-center rounded-full bg-slate-800 text-xs font-semibold text-teal-200">1</span>
              <span>
                Sign in and open your <a
                  href="https://library.playstation.com/recently-purchased"
                  target="_blank"
                  rel="noreferrer"
                  class="font-semibold text-teal-300 underline underline-offset-4"
                >PlayStation Games Library</a>.
              </span>
            </li>
            <li class="flex gap-3">
              <span class="grid size-7 shrink-0 place-items-center rounded-full bg-slate-800 text-xs font-semibold text-teal-200">2</span>
              <span>
                Download <a
                  href="/helpers/psn-collector.js"
                  class="font-semibold text-teal-300 underline underline-offset-4"
                  download
                >psn-collector.js</a>. Open the browser developer tools on the PlayStation page, choose <strong class="text-slate-100">Console</strong>, paste the whole file, and press Enter.
              </span>
            </li>
            <li class="flex gap-3">
              <span class="grid size-7 shrink-0 place-items-center rounded-full bg-slate-800 text-xs font-semibold text-teal-200">3</span>
              <span>
                A small counter panel appears in the corner. Open
                <a
                  href="https://library.playstation.com/recently-played"
                  target="_blank"
                  rel="noreferrer"
                  class="font-semibold text-teal-300 underline underline-offset-4"
                >recently played</a>
                and scroll until no more games load, then open
                <a
                  href="https://library.playstation.com/recently-purchased"
                  target="_blank"
                  rel="noreferrer"
                  class="font-semibold text-teal-300 underline underline-offset-4"
                >recently purchased</a>
                and do the same, in either order. The visible labels may be localized; the
                collector identifies these unchanged URLs and PlayStation's response fields.
                Played games are included so PlayStation Plus games are not missed.
              </span>
            </li>
            <li class="flex gap-3">
              <span class="grid size-7 shrink-0 place-items-center rounded-full bg-slate-800 text-xs font-semibold text-teal-200">4</span>
              <span>
                When both counters and the PSN name in the panel look right, press
                <strong class="text-slate-100">Download for IRI</strong>
                in the panel and upload that file below.
              </span>
            </li>
          </ol>
          <p class="mt-5 rounded-xl border border-slate-800 bg-slate-900/60 px-4 py-3 text-xs leading-5 text-slate-400">
            Being signed in lets the collector see the same game responses as the PlayStation page. IRI itself cannot read another site’s login cookies, and the downloaded file contains game details only—not cookies or login tokens. If changing sections reloads the page, paste the collector again; it keeps the already captured game list in that tab.
          </p>
        </details>
        <section class="rounded-3xl border border-slate-800 bg-slate-950/60 p-6">
          <.form
            for={@form}
            id="psn-response-form"
            phx-change="validate"
            phx-submit="preview"
            class="space-y-4"
          >
            <.live_file_input
              upload={@uploads.psn_export}
              class="block w-full rounded-2xl border border-dashed border-slate-700 p-6 text-sm text-slate-300"
            />
            <p :for={error <- upload_errors(@uploads.psn_export)} class="text-sm text-rose-300">
              {Phoenix.Naming.humanize(error)}
            </p>
            <.button id="preview-psn-response">Preview file</.button>
          </.form>
        </section>
        <section
          :if={@preview}
          id="psn-preview"
          class="rounded-3xl border border-teal-400/25 bg-teal-400/5 p-6"
        >
          <h2 class="font-semibold text-heading">
            {@preview.account.name}: {length(@preview.entries)} games
          </h2><p class="mt-1 text-sm text-slate-400">
            Purchased and played games are combined before importing.
          </p><button
            id="confirm-psn-import"
            phx-click="import"
            class="mt-5 rounded-xl bg-teal-300 px-5 py-2.5 font-semibold text-on-accent"
          >Import games</button>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp message(:file_too_large), do: "The response is larger than 20 MB."

  defp message(:missing_account),
    do: "The collector could not identify the signed-in PSN account. Download a fresh file."

  defp message(:unsupported_schema), do: "Use the current IRI PSN collector file."
  defp message(_), do: "That PlayStation collector file is incomplete or invalid."
end
