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

defmodule Iri.Sync.Schedule do
  @moduledoc "Executes the work represented by durable scheduler task kinds."

  import Ecto.Query, warn: false

  alias Iri.Accounts.Scope
  alias Iri.Integrations.ProviderAccount
  alias Iri.Repo
  alias Iri.Security.Redactor
  alias Iri.Sync
  alias Iri.Sync.{Scheduler, SyncError, SyncRun}

  @topic "sync:runs"
  @default_run_lease_seconds 10_800
  @run_poll_ms 1_000

  @doc "Expires abandoned sync runs so later manual or scheduled work can proceed."
  def recover_expired_runs(now) do
    Repo.all(
      from run in SyncRun,
        where:
          run.status in [:queued, :running] and
            (is_nil(run.lease_expires_at) or run.lease_expires_at <= ^now)
    )
    |> Enum.each(&expire_run(&1, now))

    :ok
  end

  @doc "Executes one known scheduled task while renewing its scheduler lease."
  def execute("nightly_library_maintenance", _compatibility?, heartbeat)
      when is_function(heartbeat, 0) do
    with :ok <- refresh_enabled_libraries([:steam, :gog, :xbox], heartbeat),
         :ok <- run_scheduled_igdb(false, heartbeat),
         :ok <- run_scheduled_compatibility(false, heartbeat),
         :ok <- verify_database_integrity(heartbeat) do
      :ok
    end
  end

  def execute("weekly_metadata_refresh", _compatibility?, heartbeat)
      when is_function(heartbeat, 0) do
    with :ok <- refresh_enabled_libraries([:gog], heartbeat),
         :ok <- run_scheduled_igdb(true, heartbeat),
         :ok <- run_scheduled_compatibility(true, heartbeat) do
      :ok
    end
  end

  def execute("monthly_media_maintenance", _compatibility?, heartbeat)
      when is_function(heartbeat, 0) do
    with :ok <- heartbeat.(),
         {:ok, _counts} <- Iri.Media.maintain_cache() do
      :ok
    else
      {:error, :lease_lost} ->
        {:error, "Scheduler lease expired before media maintenance completed.", true}

      {:error, reason} ->
        {:error, Redactor.redact_inspect(reason), true}
    end
  end

  def execute("pending_library_enrichment", compatibility?, heartbeat)
      when is_boolean(compatibility?) and is_function(heartbeat, 0) do
    with :ok <-
           start_and_await(
             fn -> Sync.start_igdb_sync(system_scope()) end,
             heartbeat,
             retry_when_busy: true
           ),
         :ok <- run_requested_compatibility(compatibility?, heartbeat) do
      :ok
    end
  end

  def execute(kind, _compatibility?, _heartbeat),
    do: {:error, "Unknown scheduled task #{Redactor.redact_inspect(kind)}.", false}

  defp run_requested_compatibility(false, _heartbeat), do: :ok

  defp run_requested_compatibility(true, heartbeat) do
    if defer_compatibility?() do
      :ok
    else
      start_and_await(
        fn ->
          Sync.start_compatibility_sync(system_scope(),
            sync_options: [
              protondb_gate: fn ->
                if defer_compatibility?(), do: :deferred, else: :continue
              end
            ]
          )
        end,
        heartbeat,
        retry_when_busy: true
      )
    end
  end

  defp defer_compatibility? do
    case Scheduler.defer_compatibility_for_enrichment_rerun() do
      :continue -> false
      :deferred -> true
      {:error, reason} -> raise "Could not inspect queued enrichment: #{inspect(reason)}"
    end
  end

  # Scheduled work deliberately reuses the same entry points as the admin UI.
  # This keeps provider configuration, run history, and failure reporting in one
  # path while this module only coordinates durable schedules.
  defp refresh_enabled_libraries(providers, heartbeat) do
    accounts =
      Repo.all(
        from account in ProviderAccount,
          where: account.enabled == true and account.provider in ^providers,
          order_by: [asc: account.id]
      )

    Enum.reduce_while(accounts, :ok, fn account, :ok ->
      with :ok <- heartbeat.(),
           result <- start_scheduled_library_sync(account, heartbeat) do
        case result do
          :ok -> {:cont, :ok}
          {:error, _reason, _retryable?} = error -> {:halt, error}
        end
      else
        {:error, :lease_lost} ->
          {:halt, {:error, "Scheduler lease expired while syncing libraries.", true}}
      end
    end)
  end

  defp start_scheduled_library_sync(%ProviderAccount{provider: :steam} = account, heartbeat) do
    start_and_await(
      fn -> Sync.start_steam_sync(system_scope(), account.id, enqueue_enrichment: false) end,
      heartbeat
    )
  end

  defp start_scheduled_library_sync(%ProviderAccount{provider: :gog} = account, heartbeat) do
    start_and_await(
      fn -> Sync.start_gog_sync(system_scope(), account.id, enqueue_enrichment: false) end,
      heartbeat
    )
  end

  defp start_scheduled_library_sync(%ProviderAccount{provider: :xbox} = account, heartbeat) do
    start_and_await(
      fn -> Sync.start_xbox_sync(system_scope(), account.id, enqueue_enrichment: false) end,
      heartbeat
    )
  end

  defp run_scheduled_igdb(force?, heartbeat) do
    start_and_await(fn -> Sync.start_igdb_sync(system_scope(), force: force?) end, heartbeat)
  end

  defp run_scheduled_compatibility(force?, heartbeat) do
    start_and_await(
      fn -> Sync.start_compatibility_sync(system_scope(), force: force?) end,
      heartbeat
    )
  end

  defp verify_database_integrity(heartbeat) do
    with :ok <- heartbeat.(),
         :ok <- Repo.integrity_check() do
      :ok
    else
      {:error, :lease_lost} ->
        {:error, "Scheduler lease expired before the SQLite integrity check completed.", true}

      {:error, reason} ->
        {:error, "SQLite integrity check failed: #{Redactor.redact_inspect(reason)}", false}
    end
  end

  defp start_and_await(start_fun, heartbeat, options \\ []) do
    case start_fun.() do
      {:ok, %SyncRun{} = run} ->
        await_scheduled_run(run.id, heartbeat, DateTime.utc_now(:second))

      {:error, :sync_in_progress} ->
        if Keyword.get(options, :retry_when_busy, false) do
          {:error, "Another metadata task is already running.", true}
        else
          :ok
        end

      {:error, reason} ->
        {:error, scheduled_error_message(reason), false}
    end
  end

  defp await_scheduled_run(run_id, heartbeat, started_at) do
    with :ok <- heartbeat.(),
         %SyncRun{} = run <- Repo.get(SyncRun, run_id) do
      case run.status do
        :completed ->
          :ok

        :failed ->
          scheduled_run_failure(run)

        status when status in [:queued, :running] ->
          if DateTime.diff(DateTime.utc_now(:second), started_at, :second) >= run_lease_seconds() do
            expire_run(run, DateTime.utc_now(:second))
            {:error, "Scheduled sync run #{run.id} exceeded its worker lease.", true}
          else
            receive do
            after
              @run_poll_ms -> await_scheduled_run(run_id, heartbeat, started_at)
            end
          end
      end
    else
      {:error, :lease_lost} ->
        {:error, "Scheduler lease expired while waiting for a sync run.", true}

      nil ->
        {:error, "Scheduled sync run #{run_id} no longer exists.", true}
    end
  end

  defp scheduled_run_failure(run) do
    run = Repo.preload(run, :errors)
    error = List.first(run.errors)

    message =
      if(error, do: error.message, else: "Sync run #{run.id} failed without a recorded error.")

    {:error, message, if(error, do: error.retryable, else: true)}
  end

  defp expire_run(%SyncRun{} = run, now) do
    result =
      Repo.transact(fn ->
        current = Repo.get!(SyncRun, run.id)

        if current.status in [:queued, :running] and
             (is_nil(current.lease_expires_at) or
                DateTime.compare(current.lease_expires_at, now) != :gt) do
          %SyncError{}
          |> SyncError.changeset(%{
            sync_run_id: current.id,
            stage: current.stage,
            kind: "lease_expired",
            message: "The worker lease expired before this sync run reached a terminal state.",
            retryable: true
          })
          |> Repo.insert!()

          failed_run =
            current
            |> SyncRun.progress_changeset(%{
              status: :failed,
              finished_at: now,
              failed_count: max(current.failed_count, 1),
              checkpoint: Map.merge(current.checkpoint || %{}, %{"step" => "expired"})
            })
            |> Repo.update!()

          mark_account_failed(current.provider_account_id)
          {:ok, failed_run}
        else
          {:ok, nil}
        end
      end)

    case result do
      {:ok, %SyncRun{} = failed_run} -> broadcast(failed_run)
      _other -> :ok
    end
  end

  defp mark_account_failed(nil), do: :ok

  defp mark_account_failed(account_id) do
    case Repo.get(ProviderAccount, account_id) do
      %ProviderAccount{} = account ->
        account
        |> ProviderAccount.sync_status_changeset(%{
          sync_status: "error"
        })
        |> Repo.update!()

      nil ->
        :ok
    end
  end

  defp system_scope, do: %Scope{role: :admin}

  defp scheduled_error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp scheduled_error_message(reason), do: Redactor.redact_inspect(reason)

  defp run_lease_seconds, do: @default_run_lease_seconds

  defp broadcast(run) do
    Phoenix.PubSub.broadcast(Iri.PubSub, @topic, {:sync_run_updated, run.id})
  end
end
