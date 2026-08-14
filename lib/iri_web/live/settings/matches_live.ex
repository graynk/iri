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

defmodule IriWeb.Settings.MatchesLive do
  @moduledoc "Administrator queue for deterministic and optional AI-assisted catalog matching."

  use IriWeb, :live_view

  import IriWeb.Settings.MatchesLive.Presentation

  alias Iri.AI
  alias Iri.Matches
  alias Iri.Params

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Iri.PubSub, "ai:reviews")

    focus_source_id = Params.positive_integer(params["source_id"])

    {:ok, sources} =
      Matches.list_queue(socket.assigns.current_scope, focus_source_id: focus_source_id)

    {:ok, count} = Matches.count_queue(socket.assigns.current_scope)
    {:ok, ai_reviews} = AI.list_reviews(socket.assigns.current_scope)
    {:ok, ai_summary} = AI.summary(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Match review")
     |> assign(:focus_source_id, focus_source_id)
     |> assign(:queue_count, count)
     |> assign(:queue_empty?, count == 0)
     |> assign(:ai_configuration, AI.configuration_status())
     |> assign(:ai_reviews, reviews_by_source(ai_reviews))
     |> assign(:ai_summary, ai_summary)
     |> assign(:candidate_search_queries, %{})
     |> assign(:vndb_search_queries, %{})
     |> assign(:vndb_candidates, %{})
     |> assign(:direct_match_forms, direct_match_forms(sources))
     |> assign(:candidate_search_forms, candidate_search_forms(sources, %{}))
     |> assign(:vndb_search_forms, vndb_search_forms(sources, %{}))
     |> stream(:sources, sources)}
  end

  @impl true
  def handle_info(:reviews_updated, socket), do: {:noreply, reload_queue(socket)}

  @impl true
  def handle_event("run_ai", _params, socket) do
    case AI.enqueue_unresolved(socket.assigns.current_scope, ai_ready: true) do
      {:ok, counts} ->
        {:noreply,
         socket
         |> reload_queue()
         |> put_flash(
           :info,
           "Queued #{counts.queued} AI reviews; #{counts.existing} were already queued."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("clear_ai_queue", _params, socket) do
    case AI.cancel_pending(socket.assigns.current_scope) do
      {:ok, count} ->
        {:noreply,
         socket
         |> reload_queue()
         |> put_flash(:info, "Cleared #{count} pending AI reviews.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("approve_ai", %{"review_id" => review_id}, socket) do
    case AI.approve(socket.assigns.current_scope, review_id) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> reload_queue()
         |> put_flash(:info, "AI recommendation approved and saved.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("dismiss_ai", %{"review_id" => review_id}, socket) do
    case AI.dismiss(socket.assigns.current_scope, review_id) do
      {:ok, _review} ->
        {:noreply,
         socket
         |> reload_queue()
         |> put_flash(:info, "AI recommendation dismissed.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  @impl true
  def handle_event("find_candidates", %{"source_id" => source_id}, socket) do
    case Matches.find_candidates(socket.assigns.current_scope, source_id) do
      {:ok, %{match_candidates: []}} ->
        {:noreply,
         socket
         |> reload_queue()
         |> put_flash(:error, "IGDB returned no candidates for that title.")}

      {:ok, _source} ->
        {:noreply,
         socket
         |> reload_queue()
         |> put_flash(:info, "IGDB candidates loaded for review.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event(
        "search_candidates",
        %{"candidate_search" => %{"source_id" => source_id, "query" => query}},
        socket
      ) do
    socket = remember_candidate_search(socket, source_id, query)

    case Matches.search_candidates(socket.assigns.current_scope, source_id, query) do
      {:ok, %{match_candidates: []}} ->
        {:noreply,
         socket
         |> reload_queue()
         |> put_flash(:error, "IGDB returned no candidates for #{String.trim(query)}.")}

      {:ok, _source} ->
        {:noreply,
         socket
         |> reload_queue()
         |> put_flash(:info, "IGDB search results loaded for review.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event(
        "apply_candidate",
        %{"source_id" => source_id, "igdb_id" => igdb_id},
        socket
      ) do
    case Matches.apply_candidate(socket.assigns.current_scope, source_id, igdb_id) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> reload_queue()
         |> put_flash(:info, "Manual match saved and locked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event(
        "search_vndb_candidates",
        %{"vndb_search" => %{"source_id" => source_id, "query" => query}},
        socket
      ) do
    socket = remember_vndb_search(socket, source_id, query)

    case Matches.search_vndb_candidates(socket.assigns.current_scope, source_id, query) do
      {:ok, candidates} ->
        socket = put_vndb_candidates(socket, source_id, candidates)

        {:noreply,
         socket
         |> reload_queue()
         |> maybe_put_empty_vndb_flash(candidates, query)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event(
        "apply_vndb_candidate",
        %{"source_id" => source_id, "vndb_id" => vndb_id},
        socket
      ) do
    case Matches.apply_vndb_id(socket.assigns.current_scope, source_id, vndb_id) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> reload_queue()
         |> put_flash(:info, "VNDB match saved and locked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("ignore_source", %{"source_id" => source_id}, socket) do
    case Matches.ignore_source(socket.assigns.current_scope, source_id) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> reload_queue()
         |> put_flash(:info, "This source will remain a store-only library entry.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("reject_source", %{"source_id" => source_id}, socket) do
    case Matches.reject_source(socket.assigns.current_scope, source_id) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> reload_queue()
         |> put_flash(:info, "Rejected source hidden from imported libraries.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event(
        "apply_igdb_id",
        %{"direct_match" => %{"source_id" => source_id, "igdb_id" => igdb_id}},
        socket
      ) do
    case Matches.apply_igdb_id(socket.assigns.current_scope, source_id, igdb_id) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> reload_queue()
         |> put_flash(:info, "Direct IGDB match saved and locked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp reload_queue(socket) do
    {:ok, sources} =
      Matches.list_queue(socket.assigns.current_scope,
        focus_source_id: socket.assigns.focus_source_id
      )

    {:ok, count} = Matches.count_queue(socket.assigns.current_scope)
    {:ok, ai_reviews} = AI.list_reviews(socket.assigns.current_scope)
    {:ok, ai_summary} = AI.summary(socket.assigns.current_scope)

    socket
    |> assign(:queue_count, count)
    |> assign(:queue_empty?, count == 0)
    |> assign(:ai_configuration, AI.configuration_status())
    |> assign(:ai_reviews, reviews_by_source(ai_reviews))
    |> assign(:ai_summary, ai_summary)
    |> assign(:direct_match_forms, direct_match_forms(sources))
    |> assign(
      :candidate_search_forms,
      candidate_search_forms(sources, socket.assigns.candidate_search_queries)
    )
    |> assign(:vndb_search_forms, vndb_search_forms(sources, socket.assigns.vndb_search_queries))
    |> stream(:sources, sources, reset: true)
  end

  defp error_message(%Iri.Integrations.Error{message: message}), do: message
  defp error_message(:not_configured), do: "Connect IGDB before searching for matches."
  defp error_message(:invalid_id), do: "Enter a valid game ID."
  defp error_message(:candidate_not_found), do: "The metadata provider did not return that game."
  defp error_message(:invalid_search), do: "Enter a title to search for."
  defp error_message({:ai_not_configured, reason}), do: ai_configuration_message(reason)
  defp error_message(:invalid_review_state), do: "That AI review is no longer actionable."
  defp error_message(:cannot_apply_abstention), do: "An abstention cannot be approved as a match."
  defp error_message(_reason), do: "The match operation could not be completed."

  defp direct_match_forms(sources) do
    Map.new(sources, fn source ->
      form =
        to_form(
          %{"source_id" => Integer.to_string(source.id), "igdb_id" => ""},
          as: :direct_match
        )

      {source.id, form}
    end)
  end

  defp candidate_search_forms(sources, queries) do
    Map.new(sources, fn source ->
      form =
        to_form(
          %{
            "source_id" => Integer.to_string(source.id),
            "query" => Map.get(queries, source.id, source.source_title)
          },
          as: :candidate_search
        )

      {source.id, form}
    end)
  end

  defp vndb_search_forms(sources, queries) do
    Map.new(sources, fn source ->
      form =
        to_form(
          %{
            "source_id" => Integer.to_string(source.id),
            "query" => Map.get(queries, source.id, source.source_title)
          },
          as: :vndb_search
        )

      {source.id, form}
    end)
  end

  defp remember_candidate_search(socket, source_id, query) do
    case Integer.parse(source_id) do
      {source_id, ""} ->
        update(socket, :candidate_search_queries, &Map.put(&1, source_id, String.trim(query)))

      _invalid ->
        socket
    end
  end

  defp remember_vndb_search(socket, source_id, query) do
    case Integer.parse(source_id) do
      {source_id, ""} ->
        update(socket, :vndb_search_queries, &Map.put(&1, source_id, String.trim(query)))

      _invalid ->
        socket
    end
  end

  defp put_vndb_candidates(socket, source_id, candidates) do
    case Integer.parse(source_id) do
      {source_id, ""} -> update(socket, :vndb_candidates, &Map.put(&1, source_id, candidates))
      _invalid -> socket
    end
  end

  defp maybe_put_empty_vndb_flash(socket, [], query),
    do: put_flash(socket, :error, "VNDB returned no results for #{String.trim(query)}.")

  defp maybe_put_empty_vndb_flash(socket, _candidates, _query), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto w-full max-w-6xl space-y-8">
        <header class="flex flex-col gap-5 border-b border-slate-800 pb-6 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.24em] text-teal-300">
              Admin settings
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-heading">Match review</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-slate-400">
              {@queue_count} unresolved source {if @queue_count == 1, do: "title", else: "titles"}. Only 200 are shown at once.
            </p>
          </div>
          <Layouts.settings_nav current="matches" admin?={true} />
        </header>

        <section
          id="ai-match-controls"
          class="rounded-3xl border border-slate-800 bg-slate-950/60 p-5"
        >
          <div class="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="font-semibold text-heading">AI matching</h2>
                <span class={ai_status_class(@ai_configuration)}>
                  {ai_status_label(@ai_configuration)}
                </span>
              </div>
              <p id="ai-mode-description" class="mt-1 max-w-2xl text-sm leading-6 text-slate-400">
                {ai_mode_description(@ai_configuration)}
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <.link
                id="match-history-link"
                navigate={~p"/settings/matches/history"}
                class="inline-flex min-h-11 items-center justify-center rounded-xl border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-200 transition hover:border-slate-500 hover:bg-slate-800"
              >
                <.icon name="hero-clock" class="size-4" />
                <span class="ml-2">Decision history</span>
              </.link>
              <.button
                id="run-ai-matches"
                phx-click="run_ai"
                data-confirm="Queue titles left unresolved by deterministic matching for AI review?"
                disabled={not match?({:ok, _}, @ai_configuration)}
              >
                Run AI on unresolved
              </.button>
            </div>
          </div>
          <div id="ai-queue-summary" class="mt-4 flex flex-wrap items-center gap-2 text-xs">
            <span class="rounded-full bg-slate-800 px-3 py-1.5 text-slate-300">{@ai_summary.queued} queued</span>
            <button
              :if={@ai_summary.queued > 0}
              id="clear-ai-queue"
              type="button"
              phx-click="clear_ai_queue"
              data-confirm="Clear every queued AI review that has not started?"
              class="min-h-8 rounded-lg border border-slate-700 px-2.5 py-1 font-semibold text-slate-300 transition hover:border-slate-500 hover:bg-slate-800 hover:text-slate-100 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-300"
            >
              Clear pending
            </button>
            <span class="rounded-full bg-sky-400/10 px-3 py-1.5 text-sky-200">{@ai_summary.running} running</span>
            <span class="rounded-full bg-teal-400/10 px-3 py-1.5 text-teal-100">{@ai_summary.review} to review</span>
            <span class="rounded-full bg-emerald-400/10 px-3 py-1.5 text-emerald-200">{@ai_summary.applied} applied</span>
            <span
              :if={@ai_summary.failed > 0}
              class="rounded-full bg-rose-400/10 px-3 py-1.5 text-rose-200"
            >{@ai_summary.failed} failed</span>
          </div>
          <p :if={match?({:disabled, _}, @ai_configuration)} class="mt-3 text-xs text-slate-500">
            {ai_configuration_message(elem(@ai_configuration, 1))}
          </p>
        </section>

        <section
          id="match-queue"
          phx-update="stream"
          class="grid gap-5 lg:grid-cols-2"
        >
          <div
            id="match-queue-empty"
            class="col-span-full hidden rounded-3xl border border-dashed border-emerald-400/30 bg-emerald-400/5 px-6 py-16 text-center only:block"
          >
            <.icon name="hero-check-circle" class="mx-auto size-9 text-emerald-300" />
            <p class="mt-4 font-medium text-heading">No unresolved matches</p>
            <p class="mt-1 text-sm text-slate-400">
              Exact mappings and manual decisions are complete.
            </p>
          </div>

          <article
            :for={{id, source} <- @streams.sources}
            id={id}
            class={[
              "rounded-3xl border bg-slate-950/60 p-5 shadow-xl shadow-black/10",
              if(source.id == @focus_source_id,
                do: "border-teal-400/50 ring-1 ring-teal-400/20",
                else: "border-slate-800"
              )
            ]}
          >
            <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
              <div class="min-w-0">
                <p class="text-xs font-semibold uppercase tracking-wider text-sky-300">
                  {source.provider} {source.external_id}
                </p>
                <h2 class="mt-1 truncate text-lg font-semibold text-heading">
                  {source.source_title}
                </h2>
                <p class="mt-1 text-xs text-slate-500">{source.match_method || "not checked"}</p>
              </div>
              <div class="flex shrink-0 flex-wrap items-center gap-2">
                <button
                  id={"ignore-source-#{source.id}"}
                  type="button"
                  phx-click="ignore_source"
                  phx-value-source_id={source.id}
                  data-confirm="Keep this title without catalog metadata? You can reopen it from decision history."
                  class="rounded-xl px-3 py-2 text-xs font-semibold text-slate-400 transition hover:bg-slate-800 hover:text-heading"
                >
                  Keep store-only
                </button>
                <button
                  id={"reject-source-#{source.id}"}
                  type="button"
                  phx-click="reject_source"
                  phx-value-source_id={source.id}
                  data-confirm="Reject this as a non-game and remove it from imported libraries? You can reopen it from decision history."
                  class="rounded-xl border border-rose-400/30 bg-rose-400/5 px-3 py-2 text-xs font-semibold text-rose-200 transition hover:bg-rose-400/15"
                >
                  Reject as non-game
                </button>
              </div>
            </div>

            <p
              :if={source.id == @focus_source_id}
              id={"focused-source-help-#{source.id}"}
              class="mt-4 rounded-xl border border-teal-400/20 bg-teal-400/5 px-3 py-2 text-xs leading-5 text-teal-100/80"
            >
              Choose a different match below. If this entry is software, a tool, or otherwise not a game, use “Reject as non-game” to remove it from the library.
            </p>

            <div
              :if={review = Map.get(@ai_reviews, source.id)}
              id={"ai-review-#{review.id}"}
              class="mt-5 rounded-2xl border border-teal-400/25 bg-teal-400/5 p-4"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
                <p class="text-xs font-semibold uppercase tracking-wider text-teal-100">
                  {ai_review_heading(review)}
                </p>
                <span class="text-xs text-slate-400">{review.model}</span>
              </div>
              <p :if={review.action} class="mt-2 font-medium text-heading">
                {ai_action_label(review)}
              </p>
              <p :if={review.reason} class="mt-2 text-sm leading-6 text-slate-300">{review.reason}</p>
              <p :if={review.last_error_message} class="mt-2 text-sm leading-6 text-rose-200">
                {review.last_error_message}
              </p>
              <div
                :if={failed_model_output(review)}
                id={"ai-review-model-output-#{review.id}"}
                class="mt-3 rounded-xl border border-slate-700 bg-slate-950/50 p-3"
              >
                <p class="text-xs font-semibold uppercase tracking-wider text-slate-400">
                  Model output
                </p>
                <pre class="mt-2 whitespace-pre-wrap break-words font-mono text-xs leading-5 text-slate-300">{failed_model_output(review)}</pre>
              </div>
              <div
                :if={review.status in ["recommended", "abstained", "failed"]}
                class="mt-3 flex flex-wrap gap-2"
              >
                <button
                  :if={review.action in ["match", "reject", "keep_store_only"]}
                  id={"approve-ai-review-#{review.id}"}
                  type="button"
                  phx-click="approve_ai"
                  phx-value-review_id={review.id}
                  data-confirm={ai_approval_confirmation(review)}
                  class="min-h-10 rounded-xl bg-teal-300 px-3 py-2 text-xs font-semibold text-on-accent transition hover:bg-teal-200"
                >
                  Approve
                </button>
                <button
                  id={"dismiss-ai-review-#{review.id}"}
                  type="button"
                  phx-click="dismiss_ai"
                  phx-value-review_id={review.id}
                  class="min-h-10 rounded-xl border border-slate-700 px-3 py-2 text-xs font-semibold text-slate-300 transition hover:bg-slate-800 hover:text-heading"
                >
                  Dismiss
                </button>
              </div>
            </div>

            <p
              :if={source.match_candidates == [] and source.match_method == "unmatched"}
              class="mt-5 rounded-xl border border-amber-400/20 bg-amber-400/5 px-3 py-2 text-xs leading-5 text-amber-100/80"
            >
              No IGDB candidates were found for the imported title. Try a shorter or alternate title below.
            </p>

            <.form
              for={Map.fetch!(@candidate_search_forms, source.id)}
              id={"candidate-search-form-#{source.id}"}
              phx-submit="search_candidates"
              class="mt-5"
            >
              <input
                type="hidden"
                name="candidate_search[source_id]"
                value={source.id}
              />
              <div class="flex items-end gap-2">
                <div class="min-w-0 flex-1">
                  <.search_input
                    field={Map.fetch!(@candidate_search_forms, source.id)[:query]}
                    id={"candidate-search-query-#{source.id}"}
                    label="Search IGDB"
                    placeholder="Try another title…"
                    required
                  />
                </div>
                <.button
                  id={"search-candidates-#{source.id}"}
                  class="mb-0 shrink-0"
                  phx-disable-with="Searching…"
                >
                  Search
                </.button>
              </div>
            </.form>

            <div :if={source.match_candidates != []} class="mt-5 space-y-2">
              <p class="text-xs font-semibold uppercase tracking-wider text-slate-500">
                Candidates
              </p>
              <button
                :for={candidate <- source.match_candidates}
                id={"apply-candidate-#{source.id}-#{candidate.igdb_id}"}
                type="button"
                phx-click="apply_candidate"
                phx-value-source_id={source.id}
                phx-value-igdb_id={candidate.igdb_id}
                class="min-h-11 w-full rounded-xl border border-slate-800 bg-slate-900/70 px-4 py-3 text-left transition hover:border-teal-400/40 hover:bg-teal-400/5"
              >
                <span class="block min-w-0 break-words font-medium text-slate-100">
                  {candidate.title}
                </span>
                <span
                  data-role="metadata"
                  class="mt-1 block max-w-full break-words text-xs leading-5 text-slate-500"
                >
                  {candidate_metadata(candidate)}
                </span>
                <span
                  :if={candidate_developers(candidate) != ""}
                  data-role="developer"
                  class="mt-1 block text-sm font-medium text-teal-300/90"
                >
                  {candidate_developers(candidate)}
                </span>
                <span
                  :if={candidate_summary(candidate)}
                  data-role="summary"
                  class="mt-2 line-clamp-3 block text-sm leading-6 text-slate-300"
                >
                  {candidate_summary(candidate)}
                </span>
              </button>
            </div>

            <div class="mt-5 border-t border-slate-800 pt-4">
              <p class="text-xs leading-5 text-slate-500">
                Not on IGDB? Search VNDB for visual novels and adult games.
              </p>
              <.form
                for={Map.fetch!(@vndb_search_forms, source.id)}
                id={"vndb-search-form-#{source.id}"}
                phx-submit="search_vndb_candidates"
                class="mt-3"
              >
                <.input
                  field={Map.fetch!(@vndb_search_forms, source.id)[:source_id]}
                  id={"vndb-search-source-id-#{source.id}"}
                  type="hidden"
                />
                <div class="flex items-end gap-2">
                  <div class="min-w-0 flex-1">
                    <.search_input
                      field={Map.fetch!(@vndb_search_forms, source.id)[:query]}
                      id={"vndb-search-query-#{source.id}"}
                      label="Search VNDB"
                      placeholder="Visual novel title…"
                      required
                    />
                  </div>
                  <.button
                    id={"search-vndb-candidates-#{source.id}"}
                    class="mb-0 shrink-0"
                    phx-disable-with="Searching…"
                  >
                    Search
                  </.button>
                </div>
              </.form>

              <div :if={Map.get(@vndb_candidates, source.id, []) != []} class="mt-4 space-y-2">
                <p class="text-xs font-semibold uppercase tracking-wider text-slate-500">
                  VNDB results
                </p>
                <button
                  :for={candidate <- Map.get(@vndb_candidates, source.id, [])}
                  id={"apply-vndb-candidate-#{source.id}-#{candidate["id"]}"}
                  type="button"
                  phx-click="apply_vndb_candidate"
                  phx-value-source_id={source.id}
                  phx-value-vndb_id={candidate["id"]}
                  class="min-h-11 w-full rounded-xl border border-slate-800 bg-slate-900/70 px-4 py-3 text-left transition hover:border-teal-400/40 hover:bg-teal-400/5"
                >
                  <span class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
                    <span class="min-w-0 font-medium text-slate-100">{candidate["title"]}</span>
                    <span class="shrink-0 text-xs text-slate-500">
                      {vndb_metadata(candidate)}
                    </span>
                  </span>
                  <span
                    :if={vndb_developers(candidate) != ""}
                    class="mt-1 block text-sm font-medium text-teal-100/90"
                  >
                    {vndb_developers(candidate)}
                  </span>
                  <span
                    :if={vndb_summary(candidate)}
                    class="mt-2 line-clamp-3 block text-sm leading-6 text-slate-300"
                  >
                    {vndb_summary(candidate)}
                  </span>
                </button>
              </div>
            </div>

            <.form
              for={Map.fetch!(@direct_match_forms, source.id)}
              id={"direct-igdb-form-#{source.id}"}
              phx-submit="apply_igdb_id"
              class="mt-5 border-t border-slate-800 pt-4"
            >
              <input
                type="hidden"
                name="direct_match[source_id]"
                value={source.id}
              />
              <div class="flex items-end gap-2">
                <div class="min-w-0 flex-1">
                  <.input
                    field={Map.fetch!(@direct_match_forms, source.id)[:igdb_id]}
                    id={"direct-igdb-id-#{source.id}"}
                    type="number"
                    min="1"
                    label="Match exact IGDB ID"
                    placeholder="e.g. 1372"
                    required
                  />
                </div>
                <.button id={"apply-direct-igdb-#{source.id}"} class="mb-0 shrink-0">
                  Apply ID
                </.button>
              </div>
            </.form>
          </article>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
