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

defmodule IriWeb.Settings.SyncLive do
  @moduledoc "Administrator dashboard for durable sync runs and maintenance schedules."

  use IriWeb, :live_view

  alias Iri.LocalTime
  alias Iri.Sync

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    {:ok, runs} = Sync.list_recent_runs(scope)
    {:ok, scheduled_tasks} = Sync.list_scheduled_tasks(scope)

    if connected?(socket), do: :ok = Sync.subscribe(scope)

    {:ok,
     socket
     |> assign(:page_title, "Sync runs")
     |> assign(:runs_empty?, runs == [])
     |> stream(:runs, runs)
     |> stream(:scheduled_tasks, scheduled_tasks)}
  end

  @impl true
  def handle_info({:sync_run_updated, _run_id}, socket) do
    {:ok, runs} = Sync.list_recent_runs(socket.assigns.current_scope)
    {:noreply, stream(socket, :runs, runs, reset: true)}
  end

  @impl true
  def handle_info({:scheduled_task_updated, _task_id}, socket) do
    {:ok, scheduled_tasks} = Sync.list_scheduled_tasks(socket.assigns.current_scope)
    {:noreply, stream(socket, :scheduled_tasks, scheduled_tasks, reset: true)}
  end

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
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-heading">Sync runs</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-slate-400">
              Review library imports, metadata updates, and failures.
            </p>
          </div>
          <Layouts.settings_nav current="sync" admin?={true} />
        </header>

        <section class="overflow-hidden rounded-3xl border border-slate-800 bg-slate-950/60 shadow-2xl shadow-black/20">
          <div class="border-b border-slate-800 px-6 py-5">
            <h2 class="text-lg font-semibold text-heading">Scheduled maintenance</h2>
            <p class="mt-1 text-sm text-slate-400">
              Automatic library and metadata updates.
            </p>
          </div>
          <ul id="scheduled-tasks" phx-update="stream" class="divide-y divide-slate-800">
            <li
              id="scheduled-tasks-empty"
              class="hidden px-6 py-8 text-center text-sm text-slate-400 only:block"
            >
              Scheduled maintenance has not been initialized.
            </li>
            <li
              :for={{id, task} <- @streams.scheduled_tasks}
              id={id}
              class="grid gap-3 px-6 py-5 sm:grid-cols-[1fr_auto] sm:items-center"
            >
              <div>
                <div class="flex flex-wrap items-center gap-2">
                  <p class="font-medium text-slate-100">{schedule_label(task.kind)}</p>
                  <span class={task_outcome_classes(task)}>{task_outcome_label(task)}</span>
                </div>
                <p class="mt-1 text-sm text-slate-500">{task_last_run_label(task)}</p>
                <p
                  :if={task.consecutive_failures > 0}
                  class="mt-1 text-xs text-amber-300"
                >
                  Failed {task.consecutive_failures}
                  {if task.consecutive_failures == 1, do: "time", else: "times"} in a row
                </p>
                <p :if={is_binary(task.last_error)} class="mt-2 text-sm text-amber-300">
                  {task.last_error}
                </p>
              </div>
              <time class="text-xs text-slate-500">
                Next run: {LocalTime.format(task.next_run_at, "%Y-%m-%d %H:%M %Z")}
              </time>
            </li>
          </ul>
        </section>

        <section class="overflow-hidden rounded-3xl border border-slate-800 bg-slate-950/60 shadow-2xl shadow-black/20">
          <div class="border-b border-slate-800 px-6 py-5">
            <h2 class="text-lg font-semibold text-heading">Recent runs</h2>
          </div>
          <ul id="sync-runs" phx-update="stream" class="divide-y divide-slate-800">
            <li
              id="sync-runs-empty"
              class="hidden px-6 py-12 text-center text-sm text-slate-400 only:block"
            >
              No sync runs have been recorded.
            </li>
            <li
              :for={{id, run} <- @streams.runs}
              id={id}
              class="grid gap-3 px-6 py-5 sm:grid-cols-[1fr_auto] sm:items-center"
            >
              <div>
                <div class="flex flex-wrap items-center gap-2">
                  <p class="font-medium text-slate-100">{String.replace(run.stage, "_", " ")}</p>
                  <span class={status_classes(run.status)}>{run.status}</span>
                </div>
                <p class="mt-1 text-sm text-slate-500">
                  {provider_label(run)}
                </p>
                <details :if={run.errors != []} class="mt-2 max-w-2xl">
                  <summary class="cursor-pointer text-sm font-medium text-rose-300">
                    {error_summary(run)}
                  </summary>
                  <ul class="mt-2 space-y-2">
                    <li
                      :for={error <- Enum.take(run.errors, 20)}
                      class="rounded-lg bg-rose-400/5 px-3 py-2 text-xs leading-5 text-rose-200 ring-1 ring-rose-400/15"
                    >
                      <span class="font-semibold">{String.replace(error.kind, "_", " ")}</span>
                      · {error.message}
                      <span :if={error.retryable} class="text-rose-300/60">
                        · can be retried
                      </span>
                    </li>
                  </ul>
                  <p :if={length(run.errors) > 20} class="mt-1 text-xs text-slate-500">
                    …and {length(run.errors) - 20} more.
                  </p>
                </details>
                <p
                  :if={run.status == :failed && run.errors == []}
                  data-role="missing-diagnostic"
                  class="mt-2 text-sm text-rose-300"
                >
                  This run failed without a recorded diagnostic.
                </p>
                <div
                  :if={compatibility_progress?(run)}
                  id={"sync-progress-#{run.id}"}
                  role="progressbar"
                  aria-label="Steam compatibility refresh"
                  aria-valuemin="0"
                  aria-valuenow={progress_processed(run)}
                  aria-valuemax={progress_total(run)}
                  class="mt-3 max-w-2xl"
                >
                  <div class="mb-1.5 flex items-center justify-between gap-3 text-xs text-slate-400">
                    <span data-role="progress-count">
                      {progress_processed(run)} of {progress_total(run)} checks
                    </span>
                    <span data-role="progress-phase">{compatibility_phase_label(run)}</span>
                    <span class="font-medium tabular-nums text-teal-300">
                      {progress_percent(run)}%
                    </span>
                  </div>
                  <div class="h-2 overflow-hidden rounded-full bg-slate-800 ring-1 ring-slate-700/60">
                    <div
                      data-role="progress-fill"
                      class="h-full rounded-full bg-teal-400 transition-[width] duration-500 ease-out"
                      style={"width: #{progress_percent(run)}%"}
                    >
                    </div>
                  </div>
                  <p :if={run.failed_count > 0} class="mt-1.5 text-xs text-amber-300">
                    {run.failed_count} failed so far; these will be retried later.
                  </p>
                </div>
                <p
                  :if={run.status == :running && !compatibility_progress?(run)}
                  data-role="running-step"
                  class="mt-2 text-sm text-sky-300"
                >
                  {running_message(run)}
                </p>
                <p
                  :if={run.stage == "igdb_enrichment" && run.status == :completed}
                  class="mt-2 text-xs text-slate-400"
                >
                  {run.matched_count} exact matches · {run.unmatched_count} need review · {run.updated_count} canonical records updated · {run.checkpoint[
                    "covers_cached"
                  ] || 0} covers cached
                </p>
                <p
                  :if={
                    run.stage in [
                      "steam_ownership",
                      "gog_ownership",
                      "xbox_title_history",
                      "psn_library_import",
                      "epic_library_import"
                    ] &&
                      run.status == :completed
                  }
                  class="mt-2 text-xs text-slate-400"
                >
                  {run.discovered_count} imported entries · {run.inserted_count} added · {run.updated_count} refreshed · {run.removed_count} removed
                </p>
                <p
                  :if={run.stage == "steam_compatibility" && run.status == :completed}
                  class="mt-2 text-xs text-slate-400"
                >
                  {run.updated_count} compatibility records refreshed · {run.failed_count} will retry later
                </p>
                <p
                  :if={
                    run.stage == "igdb_enrichment" && run.status == :completed &&
                      run.failed_count > 0
                  }
                  class="mt-2 text-xs text-amber-300"
                >
                  {run.failed_count} transient item {if run.failed_count == 1,
                    do: "failure was",
                    else: "failures were"} skipped safely and will be retried on the next run.
                </p>
              </div>
              <time class="text-xs text-slate-500">
                {LocalTime.format(run.inserted_at, "%Y-%m-%d %H:%M:%S %Z")}
              </time>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp provider_label(%{provider_account: %{display_name: name}}) when is_binary(name), do: name
  defp provider_label(%{provider: provider}) when not is_nil(provider), do: provider
  defp provider_label(_run), do: "system"

  defp task_outcome(%{status: :running}), do: :running

  defp task_outcome(%{consecutive_failures: failures}) when failures > 0, do: :failed

  defp task_outcome(%{last_finished_at: %DateTime{}}), do: :succeeded

  defp task_outcome(_task), do: :pending

  defp task_outcome_label(task) do
    case task_outcome(task) do
      :running -> "Running now"
      :failed -> "Last run failed"
      :succeeded -> "Last run succeeded"
      :pending -> "Not run yet"
    end
  end

  defp task_outcome_classes(task) do
    color =
      case task_outcome(task) do
        :running -> "bg-sky-400/10 text-sky-300 ring-sky-400/20"
        :failed -> "bg-rose-400/10 text-rose-300 ring-rose-400/20"
        :succeeded -> "bg-emerald-400/10 text-emerald-300 ring-emerald-400/20"
        :pending -> "bg-slate-700/40 text-slate-300 ring-slate-600/40"
      end

    ["rounded-full px-2.5 py-1 text-xs font-medium ring-1", color]
  end

  defp task_last_run_label(%{last_finished_at: %DateTime{} = finished}) do
    "Last run #{LocalTime.format(finished, "%Y-%m-%d %H:%M %Z")}"
  end

  defp task_last_run_label(_task), do: "Waiting for its first scheduled run"

  defp schedule_label("nightly_library_maintenance"), do: "Nightly library maintenance"
  defp schedule_label("weekly_metadata_refresh"), do: "Weekly metadata refresh"
  defp schedule_label("monthly_media_maintenance"), do: "Monthly media maintenance"
  defp schedule_label(kind), do: String.replace(kind, "_", " ")

  defp compatibility_progress?(run) do
    run.stage == "steam_compatibility" and run.status == :running and progress_total(run) > 0
  end

  defp progress_processed(run), do: checkpoint_integer(run, "processed")
  defp progress_total(run), do: checkpoint_integer(run, "total")

  defp progress_percent(run) do
    total = progress_total(run)

    if total > 0 do
      run
      |> progress_processed()
      |> Kernel.*(100)
      |> div(total)
      |> min(100)
    else
      0
    end
  end

  defp checkpoint_integer(%{checkpoint: checkpoint}, key) when is_map(checkpoint) do
    case Map.get(checkpoint, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp checkpoint_integer(_run, _key), do: 0

  defp compatibility_phase_label(%{checkpoint: %{"step" => "fetching_protondb"}}),
    do: "ProtonDB"

  defp compatibility_phase_label(%{checkpoint: %{"step" => "fetching_deck_compatibility"}}),
    do: "Steam Deck compatibility"

  defp compatibility_phase_label(_run), do: "Steam Store details"

  defp running_message(%{stage: "steam_compatibility"}), do: "Preparing the compatibility list…"

  defp running_message(%{stage: "igdb_enrichment", checkpoint: checkpoint}) do
    case Map.get(checkpoint || %{}, "step") do
      "matching_external_ids" -> "Matching store entries with IGDB…"
      "external_ids_complete" -> "Fetching game details from IGDB…"
      "external_metadata_complete" -> "Matching the remaining titles…"
      "title_fallback_complete" -> "Fetching details for the remaining matches…"
      "metadata_complete" -> "Caching covers…"
      "screenshots_caching" -> "Caching screenshots…"
      "automatic_ai_matching" -> "Resolving ambiguous titles with AI…"
      _ -> "Enriching game details…"
    end
  end

  defp running_message(%{stage: "steam_ownership"}), do: "Importing the Steam library…"
  defp running_message(%{stage: "gog_ownership"}), do: "Importing the GOG library…"
  defp running_message(%{stage: "xbox_title_history"}), do: "Importing Xbox games…"
  defp running_message(_run), do: "Sync in progress…"

  defp error_summary(run) do
    recorded = length(run.errors)
    total = max(recorded, run.failed_count)

    cond do
      total == 1 -> "1 error during this run"
      total == recorded -> "#{total} errors during this run"
      true -> "Details for #{recorded} of #{total} errors during this run"
    end
  end

  defp status_classes(status) do
    [
      "rounded-full px-2.5 py-1 text-xs font-medium ring-1",
      status == :completed && "bg-emerald-400/10 text-emerald-300 ring-emerald-400/20",
      status in [:queued, :running] && "bg-sky-400/10 text-sky-300 ring-sky-400/20",
      status == :failed && "bg-rose-400/10 text-rose-300 ring-rose-400/20"
    ]
  end
end
