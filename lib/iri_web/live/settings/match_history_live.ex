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

defmodule IriWeb.Settings.MatchHistoryLive do
  @moduledoc "Administrator audit history for resolved and reopened catalog matches."

  use IriWeb, :live_view

  alias Iri.Matches

  @impl true
  def mount(_params, _session, socket) do
    {:ok, decisions} = Matches.list_history(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Match decisions")
     |> assign(:actionable_reopen_ids, actionable_reopen_ids(decisions))
     |> assign(:current_decision_ids, current_decision_ids(decisions))
     |> stream(:decisions, decisions)}
  end

  @impl true
  def handle_event("reopen", %{"source_id" => source_id}, socket) do
    case Matches.reopen_source(socket.assigns.current_scope, source_id) do
      {:ok, source} ->
        {:noreply,
         socket
         |> put_flash(:info, "Decision reopened. Choose a new match or reject it as a non-game.")
         |> push_navigate(to: ~p"/settings/matches?source_id=#{source.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("reject_reopened", %{"source_id" => source_id}, socket) do
    case Matches.reject_source(socket.assigns.current_scope, source_id) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> reload_history()
         |> put_flash(:info, "Rejected as a non-game and removed from imported libraries.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, rejection_error_message(reason))}
    end
  end

  defp reload_history(socket) do
    {:ok, decisions} = Matches.list_history(socket.assigns.current_scope)

    socket
    |> assign(:actionable_reopen_ids, actionable_reopen_ids(decisions))
    |> assign(:current_decision_ids, current_decision_ids(decisions))
    |> stream(:decisions, decisions, reset: true)
  end

  defp error_message(:not_found), do: "That source no longer exists."
  defp error_message(_reason), do: "The decision could not be reopened."
  defp rejection_error_message(:not_found), do: "That source no longer exists."
  defp rejection_error_message(_reason), do: "The source could not be rejected."

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
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-heading">Match decisions</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-slate-400">
              Inspect current manual and automatic matches, correct mistakes, and audit earlier decisions.
            </p>
          </div>
          <Layouts.settings_nav current="matches" admin?={true} />
        </header>

        <div class="flex justify-start">
          <.link
            id="back-to-match-review"
            navigate={~p"/settings/matches"}
            class="inline-flex min-h-11 items-center gap-2 rounded-xl border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-200 transition hover:bg-slate-800"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Match review
          </.link>
        </div>

        <section aria-labelledby="decision-history-heading" class="space-y-4">
          <div>
            <h2 id="decision-history-heading" class="text-xl font-semibold text-heading">
              Decision history
            </h2>
            <p class="mt-1 text-sm text-slate-400">
              Current decisions and earlier changes, with their recorded explanations.
            </p>
          </div>

          <div id="match-history" phx-update="stream" class="space-y-3">
            <div
              id="match-history-empty"
              class="hidden rounded-3xl border border-dashed border-slate-700 px-6 py-14 text-center only:block"
            >
              <p class="font-medium text-heading">No recorded decisions yet</p>
            </div>

            <article
              :for={{id, decision} <- @streams.decisions}
              id={id}
              class="rounded-2xl border border-slate-800 bg-slate-950/60 p-5"
            >
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2 text-xs">
                  <span class="rounded-full bg-slate-800 px-2.5 py-1 font-semibold uppercase tracking-wider text-slate-300">
                    {decision.action |> String.replace("_", " ")}
                  </span>
                  <span class="text-slate-500">{actor_label(decision)}</span>
                  <span class="text-slate-600">{format_time(decision.inserted_at)}</span>
                  <span
                    :if={MapSet.member?(@current_decision_ids, decision.id)}
                    class="rounded-full bg-teal-400/10 px-2.5 py-1 font-semibold uppercase tracking-wider text-teal-200"
                  >
                    Current
                  </span>
                </div>
                <h3 class="mt-2 text-lg font-semibold text-heading">
                  {decision.game_source.source_title}
                </h3>
                <p class="mt-1 text-xs uppercase tracking-wider text-sky-300">
                  {decision.game_source.provider} {decision.game_source.external_id}
                </p>
                <p :if={decision.reason} class="mt-3 max-w-3xl text-sm leading-6 text-slate-300">
                  {decision.reason}
                </p>
                <p :if={decision.selected_catalog} class="mt-2 text-xs text-slate-500">
                  {String.upcase(decision.selected_catalog)} {decision.selected_external_id}
                  <span :if={decision.confidence}> · {round(decision.confidence * 100)}%</span>
                </p>
                <p
                  :if={MapSet.member?(@current_decision_ids, decision.id)}
                  class="mt-3 flex items-center gap-2 text-sm text-slate-300"
                >
                  <.icon name="hero-arrow-right" class="size-4 shrink-0 text-slate-600" />
                  <span class="truncate">{resolved_target(decision.game_source)}</span>
                </p>
                <button
                  :if={MapSet.member?(@current_decision_ids, decision.id)}
                  id={"reopen-source-#{decision.game_source_id}"}
                  type="button"
                  phx-click="reopen"
                  phx-value-source_id={decision.game_source_id}
                  data-confirm="Remove this decision and return the source to match review?"
                  class="mt-4 inline-flex min-h-10 items-center gap-1.5 rounded-xl border border-amber-400/30 px-3 py-2 text-xs font-semibold text-amber-200 transition hover:bg-amber-400/10"
                >
                  <.icon name="hero-pencil-square" class="size-4" /> Change match
                </button>
                <div
                  :if={MapSet.member?(@actionable_reopen_ids, decision.id)}
                  id={"reopened-actions-#{decision.game_source_id}"}
                  class="mt-4 flex flex-wrap gap-2"
                >
                  <.link
                    id={"continue-review-#{decision.game_source_id}"}
                    navigate={~p"/settings/matches?source_id=#{decision.game_source_id}"}
                    class="inline-flex min-h-10 items-center gap-1.5 rounded-xl border border-teal-400/30 bg-teal-400/5 px-3 py-2 text-xs font-semibold text-teal-200 transition hover:bg-teal-400/15"
                  >
                    <.icon name="hero-pencil-square" class="size-4" /> Continue review
                  </.link>
                  <button
                    id={"reject-reopened-source-#{decision.game_source_id}"}
                    type="button"
                    phx-click="reject_reopened"
                    phx-value-source_id={decision.game_source_id}
                    data-confirm="Reject this as a non-game and remove it from imported libraries? You can reopen it again from decision history."
                    class="inline-flex min-h-10 items-center gap-1.5 rounded-xl border border-rose-400/30 bg-rose-400/5 px-3 py-2 text-xs font-semibold text-rose-200 transition hover:bg-rose-400/15"
                  >
                    <.icon name="hero-no-symbol" class="size-4" /> Reject as non-game
                  </button>
                </div>
              </div>
            </article>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp actor_label(%{actor_type: "admin", admin_user: %{username: username}}),
    do: "#{username} · administrator"

  defp actor_label(%{actor_type: "ai", ai_match_review: %{model: model}}),
    do: "AI · #{model}"

  defp actor_label(%{actor_type: actor}), do: actor

  defp resolved_target(%{game: %{title: title}}), do: title
  defp resolved_target(%{catalog_kind: "rejected"}), do: "Rejected as a non-game"

  defp resolved_target(%{match_method: method}) when method in ["ignored", "ai_store_only"],
    do: "Kept as a store-only game"

  defp resolved_target(_source), do: "No catalog game"

  defp actionable_reopen_ids(decisions) do
    decisions
    |> Enum.filter(fn decision ->
      decision.action == "reopen" and not decision.game_source.manual_lock and
        is_nil(decision.game_source.game_id)
    end)
    |> Enum.uniq_by(& &1.game_source_id)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp current_decision_ids(decisions) do
    decisions
    |> Enum.uniq_by(& &1.game_source_id)
    |> Enum.filter(& &1.game_source.manual_lock)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp format_time(%DateTime{} = datetime),
    do: Iri.LocalTime.format(datetime, "%Y-%m-%d %H:%M %Z")

  defp format_time(_datetime), do: ""
end
