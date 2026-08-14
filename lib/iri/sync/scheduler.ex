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

defmodule Iri.Sync.Scheduler do
  @moduledoc "Runs durable maintenance schedules using SQLite leases instead of process state."

  use GenServer

  import Ecto.Query, warn: false

  alias Iri.Repo
  alias Iri.Security.Redactor
  alias Iri.Sync
  alias Iri.Sync.{Schedule, ScheduledTask}
  alias Iri.LocalTime

  @default_tick_ms 60_000
  @default_lease_seconds 10_800
  @default_heartbeat_seconds 60
  @enrichment_task_name "pending-library-enrichment"
  @enrichment_task_kind "pending_library_enrichment"
  @on_demand_idle_at ~U[9999-12-31 23:59:59Z]

  @definitions [
    %{name: @enrichment_task_name, kind: @enrichment_task_kind, cadence: :on_demand},
    %{name: "nightly-library-maintenance", kind: "nightly_library_maintenance", cadence: :daily},
    %{name: "weekly-metadata-refresh", kind: "weekly_metadata_refresh", cadence: :weekly},
    %{name: "monthly-media-maintenance", kind: "monthly_media_maintenance", cadence: :monthly}
  ]

  @doc "Starts the scheduler process registered as `Iri.Sync.Scheduler`."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the static definitions used to seed durable scheduled tasks."
  def task_definitions, do: @definitions

  @doc "Lists recurring maintenance tasks, excluding the internal on-demand enrichment task."
  def list_tasks do
    Repo.all(
      from task in ScheduledTask,
        where: task.kind != @enrichment_task_kind,
        order_by: [asc: task.next_run_at, asc: task.name]
    )
  end

  @doc "Requests pending metadata enrichment, coalescing concurrent requests into one rerun."
  def enqueue_library_enrichment(now_or_opts \\ [])

  def enqueue_library_enrichment(opts) when is_list(opts),
    do: enqueue_library_enrichment(DateTime.utc_now(:second), opts)

  def enqueue_library_enrichment(%DateTime{} = now), do: enqueue_library_enrichment(now, [])

  def enqueue_library_enrichment(%DateTime{} = now, opts) when is_list(opts) do
    compatibility? = Keyword.get(opts, :compatibility, false)
    :ok = ensure_tasks(now)

    result =
      Repo.transact(
        fn ->
          task = Repo.get_by!(ScheduledTask, name: @enrichment_task_name)

          task
          |> ScheduledTask.changeset(%{
            next_run_at: now,
            rerun_requested: task.status == :running,
            compatibility_requested: task.compatibility_requested or compatibility?
          })
          |> Repo.update()
        end,
        mode: :immediate
      )

    case result do
      {:ok, task} ->
        notify_task_update(task.id, 1)
        wake_scheduler()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Preserves compatibility work and defers it when a newer enrichment pass is queued."
  def defer_compatibility_for_enrichment_rerun do
    result =
      Repo.transact_with_busy_retry(
        fn ->
          case Repo.get_by(ScheduledTask, name: @enrichment_task_name) do
            %ScheduledTask{status: :running, rerun_requested: true} = task ->
              if task.compatibility_requested do
                {:ok, :deferred}
              else
                task
                |> ScheduledTask.changeset(%{compatibility_requested: true})
                |> Repo.update!()

                {:ok, :deferred}
              end

            _task ->
              {:ok, :continue}
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, decision} -> decision
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Idempotently creates the durable rows for every known schedule."
  def ensure_tasks(now \\ DateTime.utc_now(:second)) do
    timestamp = DateTime.utc_now(:second)

    rows =
      Enum.map(@definitions, fn definition ->
        %{
          name: definition.name,
          kind: definition.kind,
          status: :idle,
          next_run_at: next_scheduled_at(definition, now),
          rerun_requested: false,
          compatibility_requested: false,
          inserted_at: timestamp,
          updated_at: timestamp
        }
      end)

    {_, _} =
      Repo.insert_all(ScheduledTask, rows,
        on_conflict: :nothing,
        conflict_target: :name
      )

    :ok
  end

  @doc "Claims due scheduled-task rows with SQLite-backed leases."
  def claim_due_tasks(now \\ DateTime.utc_now(:second)) do
    task_ids =
      Repo.all(
        from task in ScheduledTask,
          where:
            (task.status == :idle and task.next_run_at <= ^now) or
              (task.status == :running and task.lease_expires_at <= ^now),
          select: task.id
      )

    Enum.flat_map(task_ids, fn task_id ->
      case claim_task(task_id, now) do
        {:ok, task} -> [task]
        :not_due -> []
      end
    end)
  end

  @doc "Refreshes a claimed task lease, returning `{:error, :lease_lost}` if it no longer belongs to this runner."
  def heartbeat(%ScheduledTask{id: id, lease_token: token}) when is_binary(token),
    do: heartbeat(id, token)

  def heartbeat(task_id, lease_token) do
    heartbeat(task_id, lease_token, DateTime.utc_now(:second))
  end

  @doc "Extends a claimed task lease when its token still owns the task."
  def heartbeat(task_id, lease_token, %DateTime{} = now) do
    lease_expires_at =
      Repo.one(
        from task in ScheduledTask,
          where:
            task.id == ^task_id and task.status == :running and
              task.lease_token == ^lease_token,
          select: task.lease_expires_at
      )

    refresh_cutoff =
      DateTime.add(now, @default_lease_seconds - heartbeat_interval_seconds(), :second)

    if is_nil(lease_expires_at) or DateTime.compare(lease_expires_at, refresh_cutoff) != :gt do
      refresh_heartbeat(task_id, lease_token, now)
    else
      :ok
    end
  end

  defp refresh_heartbeat(task_id, lease_token, now) do
    refreshed_lease_expires_at = lease_expires_at(now)

    {count, _} =
      Repo.update_all(
        from(task in ScheduledTask,
          where:
            task.id == ^task_id and task.status == :running and task.lease_token == ^lease_token
        ),
        set: [lease_expires_at: refreshed_lease_expires_at, updated_at: now]
      )

    if count == 1, do: :ok, else: {:error, :lease_lost}
  end

  @impl true
  def init(opts) do
    now = DateTime.utc_now(:second)
    :ok = ensure_tasks(now)
    :ok = realign_future_recurring_tasks(now)

    state = %{
      tick_ms: Keyword.get(opts, :tick_ms, @default_tick_ms)
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_due_tasks()

    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:wake, state) do
    run_due_tasks()
    {:noreply, state}
  end

  defp start_task(task) do
    case Task.Supervisor.start_child(Iri.Sync.TaskSupervisor, fn -> execute_task(task) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> complete(task, {:error, Redactor.redact_inspect(reason), true})
    end
  end

  defp execute_task(task) do
    result =
      try do
        Schedule.execute(task.kind, task.compatibility_requested, fn -> heartbeat(task) end)
      rescue
        exception -> {:error, Redactor.exception_message(exception), true}
      catch
        kind, reason -> {:error, "#{kind}: #{Redactor.redact_inspect(reason)}", true}
      end

    complete(task, result)
  end

  @doc "Records a claimed task result, scheduling its next run or retry."
  def complete(task, result)

  def complete(%ScheduledTask{} = task, :ok) do
    now = DateTime.utc_now(:second)
    definition = Enum.find(@definitions, &(&1.name == task.name))

    result =
      Repo.transact(
        fn ->
          case Repo.get_by(ScheduledTask,
                 id: task.id,
                 status: :running,
                 lease_token: task.lease_token
               ) do
            nil ->
              {:ok, nil}

            current ->
              rerun? =
                definition.cadence == :on_demand and
                  current.rerun_requested

              current
              |> ScheduledTask.changeset(%{
                status: :idle,
                next_run_at:
                  if(rerun?, do: current.next_run_at, else: next_scheduled_at(definition, now)),
                lease_token: nil,
                lease_expires_at: nil,
                consecutive_failures: 0,
                last_finished_at: now,
                last_error: nil,
                rerun_requested: rerun?,
                compatibility_requested: rerun? and current.compatibility_requested
              })
              |> Repo.update()
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, nil} ->
        :ok

      {:ok, updated} ->
        notify_task_update(updated.id, 1)
        if DateTime.compare(updated.next_run_at, now) != :gt, do: wake_scheduler()
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  def complete(%ScheduledTask{} = task, {:error, reason, retryable?})
      when is_boolean(retryable?) do
    now = DateTime.utc_now(:second)
    reason = reason |> to_string() |> String.slice(0, 1_000)

    if retryable? do
      failures = task.consecutive_failures + 1

      {count, _} =
        Repo.update_all(
          from(current in ScheduledTask,
            where:
              current.id == ^task.id and current.status == :running and
                current.lease_token == ^task.lease_token
          ),
          set: [
            status: :idle,
            next_run_at: DateTime.add(now, retry_delay_seconds(failures), :second),
            lease_token: nil,
            lease_expires_at: nil,
            consecutive_failures: failures,
            last_finished_at: now,
            last_error: reason,
            rerun_requested: false,
            compatibility_requested: false,
            updated_at: now
          ]
        )

      notify_task_update(task.id, count)
    else
      definition = Enum.find(@definitions, &(&1.name == task.name))

      {count, _} =
        Repo.update_all(
          from(current in ScheduledTask,
            where:
              current.id == ^task.id and current.status == :running and
                current.lease_token == ^task.lease_token
          ),
          set: [
            status: :idle,
            next_run_at: next_scheduled_at(definition, now),
            lease_token: nil,
            lease_expires_at: nil,
            last_finished_at: now,
            last_error: reason,
            rerun_requested: false,
            compatibility_requested: false,
            updated_at: now
          ]
        )

      notify_task_update(task.id, count)
    end
  end

  defp claim_task(task_id, now) do
    lease_token = Ecto.UUID.generate()

    result =
      Repo.transact(
        fn ->
          {count, _} =
            Repo.update_all(
              from(task in ScheduledTask,
                where:
                  task.id == ^task_id and
                    ((task.status == :idle and task.next_run_at <= ^now) or
                       (task.status == :running and task.lease_expires_at <= ^now))
              ),
              set: [
                status: :running,
                lease_token: lease_token,
                lease_expires_at: lease_expires_at(now),
                updated_at: now
              ]
            )

          if count == 1 do
            task = Repo.get_by!(ScheduledTask, id: task_id, lease_token: lease_token)

            if task.kind == @enrichment_task_kind do
              compatibility_requested = task.compatibility_requested

              with {:ok, updated} <-
                     task
                     |> ScheduledTask.changeset(%{
                       next_run_at: @on_demand_idle_at,
                       rerun_requested: false,
                       compatibility_requested: false
                     })
                     |> Repo.update() do
                # The runner must see the flags as they were when the work was
                # queued, while the stored row starts collecting the next batch.
                {:ok, %{updated | compatibility_requested: compatibility_requested}}
              end
            else
              {:ok, task}
            end
          else
            {:ok, nil}
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, %ScheduledTask{} = task} ->
        notify_task_update(task.id, 1)
        {:ok, task}

      _ ->
        :not_due
    end
  end

  defp next_scheduled_at(%{cadence: :on_demand}, _now), do: @on_demand_idle_at
  defp next_scheduled_at(%{cadence: :daily}, now), do: next_daily(now, 3)
  defp next_scheduled_at(%{cadence: :weekly}, now), do: next_weekly(now, 7, 4)
  defp next_scheduled_at(%{cadence: :monthly}, now), do: next_monthly(now, 5)

  defp next_daily(now, hour) do
    date = LocalTime.date(now)
    target = datetime_at(date, hour)

    if DateTime.compare(target, now) == :gt,
      do: target,
      else: datetime_at(Date.add(date, 1), hour)
  end

  defp next_weekly(now, day_of_week, hour) do
    date = LocalTime.date(now)
    days_until = rem(day_of_week - Date.day_of_week(date) + 7, 7)
    target = datetime_at(Date.add(date, days_until), hour)

    if DateTime.compare(target, now) == :gt,
      do: target,
      else: datetime_at(Date.add(date, days_until + 7), hour)
  end

  defp next_monthly(now, hour) do
    date = LocalTime.date(now)
    first_of_current_month = Date.new!(date.year, date.month, 1)
    current_target = datetime_at(first_of_current_month, hour)

    if DateTime.compare(current_target, now) == :gt do
      current_target
    else
      {year, month} =
        if date.month == 12, do: {date.year + 1, 1}, else: {date.year, date.month + 1}

      datetime_at(Date.new!(year, month, 1), hour)
    end
  end

  defp datetime_at(date, hour), do: LocalTime.utc_at(date, hour)

  defp realign_future_recurring_tasks(now) do
    @definitions
    |> Enum.reject(&(&1.cadence == :on_demand))
    |> Enum.each(fn definition ->
      Repo.update_all(
        from(task in ScheduledTask,
          where:
            task.name == ^definition.name and task.status == :idle and
              task.consecutive_failures == 0 and task.next_run_at > ^now
        ),
        set: [next_run_at: next_scheduled_at(definition, now), updated_at: now]
      )
    end)

    :ok
  end

  defp lease_expires_at(now), do: DateTime.add(now, @default_lease_seconds, :second)

  defp heartbeat_interval_seconds do
    @default_lease_seconds
    |> div(3)
    |> max(1)
    |> min(@default_heartbeat_seconds)
  end

  defp retry_delay_seconds(failures), do: min(300 * Integer.pow(2, min(failures - 1, 6)), 21_600)

  defp run_due_tasks do
    now = DateTime.utc_now(:second)
    :ok = ensure_tasks(now)
    :ok = Sync.recover_expired_runs(now)

    now
    |> claim_due_tasks()
    |> Enum.each(&start_task/1)
  end

  defp wake_scheduler do
    cond do
      Process.whereis(__MODULE__) ->
        GenServer.cast(__MODULE__, :wake)

      Application.get_env(:iri, :on_demand_enrichment_enabled, true) ->
        start_due_enrichment_task()

      true ->
        :ok
    end

    :ok
  end

  defp start_due_enrichment_task do
    now = DateTime.utc_now(:second)
    task = Repo.get_by(ScheduledTask, name: @enrichment_task_name)

    case task && claim_task(task.id, now) do
      {:ok, claimed} -> start_task(claimed)
      _ -> :ok
    end
  end

  defp notify_task_update(_task_id, 0), do: :ok

  defp notify_task_update(task_id, _count) do
    Phoenix.PubSub.broadcast(Iri.PubSub, "sync:runs", {:scheduled_task_updated, task_id})
  end
end
