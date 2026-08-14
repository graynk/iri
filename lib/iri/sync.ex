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

defmodule Iri.Sync do
  @moduledoc "Durable synchronization run orchestration."

  import Ecto.Query, warn: false
  require Logger

  alias Iri.Accounts.Scope
  alias Iri.AI
  alias Iri.Integrations
  alias Iri.Integrations.ProviderAccount
  alias Iri.Integrations.Steam.{Client, Compatibility, Reconciler, StoreClient}
  alias Iri.Integrations.GOG.Client, as: GOGClient
  alias Iri.Integrations.GOG.Reconciler, as: GOGReconciler
  alias Iri.Integrations.LibraryReconciler
  alias Iri.Integrations.Xbox.Client, as: XboxClient
  alias Iri.Integrations.IGDB.Enricher
  alias Iri.Integrations.IGDB.Client, as: IGDBClient
  alias Iri.Repo
  alias Iri.Security.{Redactor, SafeText}
  alias Iri.Sync.{ErrorNormalizer, Schedule, SyncError, SyncRun}

  @topic "sync:runs"
  @default_run_lease_seconds 10_800

  @doc "Subscribes an administrator process to sync-run updates over Phoenix PubSub."
  def subscribe(%Scope{} = scope) do
    with :ok <- authorize_user(scope) do
      Phoenix.PubSub.subscribe(Iri.PubSub, @topic)
    end
  end

  @doc "Lists recent durable sync runs and their recorded failures. Administrators only."
  def list_recent_runs(%Scope{} = scope, limit \\ 25) do
    with :ok <- authorize_admin(scope) do
      runs =
        Repo.all(
          from run in SyncRun,
            order_by: [desc: run.inserted_at],
            limit: ^limit,
            preload: [:provider_account, :errors]
        )

      {:ok, Enum.map(runs, &sanitize_run_diagnostics/1)}
    end
  end

  @doc "Ensures and lists durable scheduled maintenance tasks. Administrators only."
  def list_scheduled_tasks(%Scope{} = scope) do
    with :ok <- authorize_admin(scope) do
      :ok = Iri.Sync.Scheduler.ensure_tasks()

      tasks =
        Enum.map(Iri.Sync.Scheduler.list_tasks(), fn task ->
          %{task | last_error: SafeText.display(task.last_error)}
        end)

      {:ok, tasks}
    end
  end

  defp sanitize_run_diagnostics(%SyncRun{} = run) do
    errors =
      Enum.map(run.errors, fn error ->
        %{error | message: SafeText.display(error.message)}
      end)

    %{run | errors: errors}
  end

  @doc "Marks queued or running sync runs with expired worker leases as failed."
  def recover_expired_runs(now \\ DateTime.utc_now(:second)) do
    Schedule.recover_expired_runs(now)
  end

  @doc "Starts a test-only asynchronous sync run. Administrators only."
  def start_dummy_sync(%Scope{} = scope, provider_account_id \\ nil) do
    with :ok <- authorize_admin(scope),
         :ok <- recover_expired_runs(),
         {:ok, account} <- load_optional_account(provider_account_id),
         {:ok, run} <- create_run(account) do
      case Task.Supervisor.start_child(Iri.Sync.TaskSupervisor, fn ->
             execute_dummy(run.id)
           end) do
        {:ok, _pid} -> {:ok, run}
        {:error, reason} -> fail_to_start(run, reason)
      end
    end
  end

  @doc "Starts a durable Steam ownership import for an accessible Steam account."
  def start_steam_sync(%Scope{} = scope, provider_account_id, options \\ []) do
    start_account_sync(scope, provider_account_id, :steam, options)
  end

  @doc "Starts canonical metadata enrichment for pending or stale library sources."
  def start_igdb_sync(%Scope{} = scope, options \\ []) do
    provider_account_id = Keyword.get(options, :provider_account_id)
    force? = Keyword.get(options, :force, false)
    compatibility_after? = Keyword.get(options, :compatibility_after, false)
    compatibility_options = Keyword.get(options, :compatibility_options, [])
    automatic_ai_options = Keyword.get(options, :automatic_ai_options, [])

    with :ok <- authorize_admin(scope),
         :ok <- recover_expired_runs(),
         {:ok, account} <- load_enrichment_account(provider_account_id),
         false <- active_igdb_run?(),
         {:ok, run} <- create_igdb_run(account, force?) do
      client =
        Keyword.get(options, :client, Application.get_env(:iri, :igdb_client, IGDBClient))

      client_options = Keyword.get(options, :client_options, [])

      enrich_options =
        options
        |> Keyword.get(:enrich_options, [])
        |> Keyword.put(:provider_account_id, account && account.id)
        |> Keyword.put(:force, force?)

      case Task.Supervisor.start_child(Iri.Sync.TaskSupervisor, fn ->
             execute_igdb(
               run.id,
               client,
               client_options,
               enrich_options,
               compatibility_after?,
               compatibility_options,
               automatic_ai_options
             )
           end) do
        {:ok, _pid} -> {:ok, run}
        {:error, reason} -> fail_to_start(run, reason)
      end
    else
      nil -> {:error, :provider_account_not_found}
      %ProviderAccount{} -> {:error, :unsupported_provider_account}
      true -> {:error, :sync_in_progress}
      error -> error
    end
  end

  @doc "Starts a durable GOG ownership import for an accessible GOG account."
  def start_gog_sync(%Scope{} = scope, provider_account_id, options \\ []) do
    start_account_sync(scope, provider_account_id, :gog, options)
  end

  @doc "Starts a durable Xbox played-history import for an accessible Xbox account."
  def start_xbox_sync(%Scope{} = scope, provider_account_id, options \\ []) do
    start_account_sync(scope, provider_account_id, :xbox, options)
  end

  defp start_account_sync(scope, provider_account_id, provider, options) do
    spec = account_sync_spec(provider)
    enqueue_enrichment? = Keyword.get(options, :enqueue_enrichment, true)

    with :ok <- authorize_account_owner(scope, provider_account_id),
         :ok <- recover_expired_runs(),
         %ProviderAccount{provider: ^provider, enabled: true} = account <-
           Repo.get(ProviderAccount, provider_account_id),
         false <- active_run?(account.id),
         {:ok, run} <- create_account_run(account, spec) do
      client =
        Keyword.get(
          options,
          :client,
          Application.get_env(:iri, spec.client_config_key, spec.default_client)
        )

      client_options = Keyword.get(options, :client_options, [])

      case Task.Supervisor.start_child(Iri.Sync.TaskSupervisor, fn ->
             spec.executor.(run.id, client, client_options, enqueue_enrichment?)
           end) do
        {:ok, _pid} -> {:ok, run}
        {:error, reason} -> fail_to_start(run, reason)
      end
    else
      nil -> {:error, :provider_account_not_found}
      %ProviderAccount{} -> {:error, spec.mismatch_error}
      true -> {:error, :sync_in_progress}
      error -> error
    end
  end

  defp account_sync_spec(:steam) do
    %{
      provider: :steam,
      stage: "steam_ownership",
      running_step: "fetching_owned_games",
      client_config_key: :steam_client,
      default_client: Client,
      executor: &execute_steam/4,
      mismatch_error: :not_a_steam_account,
      enrichment_count_field: :new_source_count,
      compatibility: true,
      checkpoint_new_sources: true,
      checkpoint_failure_kind: true,
      normalize_error: &normalize_sync_error/1
    }
  end

  defp account_sync_spec(:gog) do
    %{
      provider: :gog,
      stage: "gog_ownership",
      running_step: "fetching_owned_products",
      client_config_key: :gog_client,
      default_client: GOGClient,
      executor: &execute_gog/4,
      mismatch_error: :not_a_gog_account,
      enrichment_count_field: :new_source_count,
      compatibility: false,
      checkpoint_new_sources: true,
      checkpoint_failure_kind: true,
      normalize_error: &normalize_gog_error/1
    }
  end

  defp account_sync_spec(:xbox) do
    %{
      provider: :xbox,
      stage: "xbox_title_history",
      running_step: "fetching_title_history",
      client_config_key: :xbox_client,
      default_client: XboxClient,
      executor: &execute_xbox/4,
      mismatch_error: :not_an_xbox_account,
      enrichment_count_field: :inserted_count,
      compatibility: false,
      checkpoint_new_sources: false,
      checkpoint_failure_kind: false,
      normalize_error: &normalize_xbox_error/1
    }
  end

  @doc "Starts a durable Steam store, Deck, and ProtonDB compatibility refresh."
  def start_compatibility_sync(%Scope{} = scope, options \\ []) do
    force? = Keyword.get(options, :force, false)

    with :ok <- authorize_admin(scope),
         :ok <- recover_expired_runs(),
         false <- active_compatibility_run?(),
         {:ok, run} <- create_compatibility_run(force?) do
      client = Keyword.get(options, :client, StoreClient)
      client_options = Keyword.get(options, :client_options, [])
      sync_options = Keyword.get(options, :sync_options, [])

      case Task.Supervisor.start_child(Iri.Sync.TaskSupervisor, fn ->
             execute_compatibility(run.id, client, client_options, sync_options, force?)
           end) do
        {:ok, _pid} -> {:ok, run}
        {:error, reason} -> fail_to_start(run, reason)
      end
    else
      true -> {:error, :sync_in_progress}
      error -> error
    end
  end

  defp create_run(account) do
    attrs = %{
      provider_account_id: account && account.id,
      provider: account && account.provider,
      stage: "foundation_check",
      status: :queued,
      checkpoint: %{"step" => "queued"},
      lease_expires_at: run_lease_expires_at()
    }

    %SyncRun{}
    |> SyncRun.create_changeset(attrs)
    |> Repo.insert()
    |> tap_success(&broadcast/1)
  end

  defp create_igdb_run(account, force?) do
    %SyncRun{}
    |> SyncRun.create_changeset(%{
      provider_account_id: account && account.id,
      provider: :igdb,
      stage: "igdb_enrichment",
      status: :queued,
      checkpoint: %{
        "step" => "queued",
        "force" => force?,
        "scope" => if(account, do: "account", else: "all")
      },
      lease_expires_at: run_lease_expires_at()
    })
    |> Repo.insert()
    |> tap_success(&broadcast/1)
  end

  defp create_account_run(account, spec) do
    %SyncRun{}
    |> SyncRun.create_changeset(%{
      provider_account_id: account.id,
      provider: spec.provider,
      stage: spec.stage,
      status: :queued,
      checkpoint: %{"step" => "queued"},
      lease_expires_at: run_lease_expires_at()
    })
    |> Repo.insert()
    |> tap_success(&broadcast/1)
  end

  defp create_compatibility_run(force?) do
    %SyncRun{}
    |> SyncRun.create_changeset(%{
      provider: :steam,
      stage: "steam_compatibility",
      status: :queued,
      checkpoint: %{"step" => "queued", "force" => force?},
      lease_expires_at: run_lease_expires_at()
    })
    |> Repo.insert()
    |> tap_success(&broadcast/1)
  end

  defp system_scope, do: %Scope{role: :admin}

  defp run_lease_expires_at do
    DateTime.add(DateTime.utc_now(:second), @default_run_lease_seconds, :second)
  end

  defp execute_compatibility(id, client, client_options, sync_options, force?) do
    run = Repo.get!(SyncRun, id)

    run =
      run
      |> SyncRun.progress_changeset(%{
        status: :running,
        started_at: DateTime.utc_now(:second),
        checkpoint: %{"step" => "fetching_compatibility"}
      })
      |> Repo.update!()

    broadcast(run)

    progress = fn details -> update_compatibility_progress(id, details) end

    {:ok, counts} =
      Compatibility.sync(
        Keyword.merge(sync_options,
          client: client,
          client_options: client_options,
          force: force?,
          progress: progress
        )
      )

    complete_compatibility_sync(run, counts, force?)
  rescue
    exception ->
      case Repo.get(SyncRun, id) do
        %SyncRun{} = run -> fail_compatibility_sync(run, exception)
        nil -> :ok
      end
  end

  defp complete_compatibility_sync(run, counts, force?) do
    run = Repo.get!(SyncRun, run.id)

    {:ok, run} =
      Repo.transact(fn ->
        run =
          run
          |> SyncRun.progress_changeset(%{
            status: :completed,
            finished_at: DateTime.utc_now(:second),
            discovered_count: counts.discovered_count,
            updated_count: counts.updated_count,
            failed_count: counts.failed_count,
            checkpoint: %{
              "step" => "complete",
              "force" => force?,
              "partial_failures" => counts.failed_count,
              "steam_updated" => counts.steam_updated_count,
              "protondb_modified" => counts.protondb_modified_count,
              "protondb_not_modified" => counts.protondb_not_modified_count,
              "protondb_deferred" => counts.protondb_deferred_count
            }
          })
          |> Repo.update!()

        persist_partial_errors(run, "steam_compatibility", Map.get(counts, :failures, []))
        {:ok, run}
      end)

    broadcast(run)
  end

  defp fail_compatibility_sync(run, reason) do
    run = Repo.get!(SyncRun, run.id)
    now = DateTime.utc_now(:second)

    Repo.transact(fn ->
      %SyncError{}
      |> SyncError.changeset(%{
        sync_run_id: run.id,
        stage: "steam_compatibility",
        kind: "unexpected",
        message: compatibility_error_message(reason),
        retryable: true
      })
      |> Repo.insert!()

      failed_run =
        run
        |> SyncRun.progress_changeset(%{
          status: :failed,
          finished_at: now,
          failed_count: 1,
          checkpoint: %{"step" => "failed"}
        })
        |> Repo.update!()

      {:ok, failed_run}
    end)
    |> case do
      {:ok, failed_run} -> broadcast(failed_run)
      _error -> :ok
    end
  end

  defp update_compatibility_progress(run_id, details) do
    case Repo.get(SyncRun, run_id) do
      %SyncRun{} = run ->
        run =
          run
          |> SyncRun.progress_changeset(%{
            status: :running,
            discovered_count: details.discovered_count,
            updated_count: details.updated_count,
            failed_count: details.failed_count,
            checkpoint: %{
              "step" => details.step,
              "processed" => details.processed_count,
              "total" => details.total_count
            }
          })
          |> Repo.update!()

        broadcast(run)

      nil ->
        :ok
    end
  end

  defp execute_gog(id, client, client_options, enqueue_enrichment?) do
    run = Repo.get!(SyncRun, id)
    account = Repo.get!(ProviderAccount, run.provider_account_id)
    spec = account_sync_spec(:gog)
    run = begin_account_sync(run, account, spec)

    result =
      with {:ok, games} <- client.fetch_library(account, %{}, client_options),
           {:ok, counts} <- GOGReconciler.reconcile(account, games) do
        {:ok, counts}
      end

    case result do
      {:ok, counts} -> complete_account_sync(run, account, counts, enqueue_enrichment?, spec)
      {:error, reason} -> fail_account_sync(run, account, reason, spec)
    end
  rescue
    exception ->
      case {Repo.get(SyncRun, id), Repo.get_by(ProviderAccount, id: run_account_id(id))} do
        {%SyncRun{} = run, %ProviderAccount{} = account} ->
          fail_account_sync(run, account, exception, account_sync_spec(:gog))

        _other ->
          :ok
      end
  end

  defp execute_xbox(id, client, client_options, enqueue_enrichment?) do
    run = Repo.get!(SyncRun, id)
    account = Repo.get!(ProviderAccount, run.provider_account_id)
    spec = account_sync_spec(:xbox)
    run = begin_account_sync(run, account, spec)

    result =
      with {:ok, {key, auth_options}} <- Integrations.openxbl_credentials_for_sync(account),
           {:ok, entries} <-
             client.fetch_library(account, key, Keyword.merge(client_options, auth_options)),
           {:ok, counts} <- LibraryReconciler.reconcile(account, entries, false) do
        retired = LibraryReconciler.retire_matching(account, &XboxClient.non_game_source?/1)
        {:ok, %{counts | removed_count: counts.removed_count + retired}}
      end

    case result do
      {:ok, counts} -> complete_account_sync(run, account, counts, enqueue_enrichment?, spec)
      {:error, reason} -> fail_account_sync(run, account, reason, spec)
    end
  rescue
    exception ->
      case {Repo.get(SyncRun, id), Repo.get(ProviderAccount, run_account_id(id))} do
        {%SyncRun{} = run, %ProviderAccount{} = account} ->
          fail_account_sync(run, account, exception, account_sync_spec(:xbox))

        _ ->
          :ok
      end
  end

  defp begin_account_sync(run, account, spec) do
    now = DateTime.utc_now(:second)

    run =
      run
      |> SyncRun.progress_changeset(%{
        status: :running,
        started_at: now,
        checkpoint: %{"step" => spec.running_step}
      })
      |> Repo.update!()

    account
    |> ProviderAccount.sync_status_changeset(%{
      sync_status: "syncing"
    })
    |> Repo.update!()

    broadcast(run)
    run
  end

  defp complete_account_sync(run, account, counts, enqueue_enrichment?, spec) do
    now = DateTime.utc_now(:second)
    checkpoint = completion_checkpoint(counts, spec)

    run =
      run
      |> SyncRun.progress_changeset(
        counts
        |> Map.take([:discovered_count, :inserted_count, :updated_count, :removed_count])
        |> Map.merge(%{
          status: :completed,
          finished_at: now,
          checkpoint: checkpoint
        })
      )
      |> Repo.update!()

    account
    |> then(&Repo.get!(ProviderAccount, &1.id))
    |> ProviderAccount.sync_status_changeset(%{
      sync_status: "ready"
    })
    |> Repo.update!()

    broadcast(run)

    maybe_enqueue_enrichment(
      Map.fetch!(counts, spec.enrichment_count_field),
      enqueue_enrichment?,
      compatibility: spec.compatibility
    )
  end

  defp completion_checkpoint(counts, %{checkpoint_new_sources: true}) do
    %{"step" => "complete", "new_sources" => Map.fetch!(counts, :new_source_count)}
  end

  defp completion_checkpoint(_counts, %{checkpoint_new_sources: false}),
    do: %{"step" => "complete"}

  defp fail_account_sync(run, account, reason, spec) do
    now = DateTime.utc_now(:second)
    error = spec.normalize_error.(reason)
    error_kind = Atom.to_string(error.kind)
    checkpoint = failure_checkpoint(error_kind, spec)

    Repo.transact(fn ->
      %SyncError{}
      |> SyncError.changeset(%{
        sync_run_id: run.id,
        stage: spec.stage,
        kind: error_kind,
        message: error.message,
        retryable: error.retryable
      })
      |> Repo.insert!()

      failed_run =
        run
        |> SyncRun.progress_changeset(%{
          status: :failed,
          finished_at: now,
          failed_count: 1,
          checkpoint: checkpoint
        })
        |> Repo.update!()

      account
      |> then(&Repo.get!(ProviderAccount, &1.id))
      |> ProviderAccount.sync_status_changeset(%{
        sync_status: "error"
      })
      |> Repo.update!()

      {:ok, failed_run}
    end)
    |> case do
      {:ok, failed_run} -> broadcast(failed_run)
      _error -> :ok
    end
  end

  defp failure_checkpoint(kind, %{checkpoint_failure_kind: true}),
    do: %{"step" => "failed", "kind" => kind}

  defp failure_checkpoint(_kind, %{checkpoint_failure_kind: false}),
    do: %{"step" => "failed"}

  defp execute_igdb(
         id,
         client,
         client_options,
         enrich_options,
         compatibility_after?,
         compatibility_options,
         automatic_ai_options
       ) do
    run = Repo.get!(SyncRun, id)

    run =
      run
      |> SyncRun.progress_changeset(%{
        status: :running,
        started_at: DateTime.utc_now(:second),
        checkpoint: %{"step" => "matching_external_ids"}
      })
      |> Repo.update!()

    broadcast(run)

    result =
      with {:ok, credentials} <-
             Integrations.igdb_credentials_for_sync(client, client_options),
           progress = fn step, details -> update_igdb_progress(id, step, details) end,
           {:ok, counts} <-
             Enricher.enrich(
               credentials,
               Keyword.merge(enrich_options,
                 client: client,
                 client_options: client_options,
                 progress: progress
               )
             ) do
        {:ok, counts}
      end

    case result do
      {:ok, counts} ->
        run_automatic_ai(id, counts.source_ids, automatic_ai_options)
        run = complete_igdb_sync(run, counts)
        maybe_start_compatibility(run, compatibility_after?, compatibility_options)

      {:error, reason} ->
        fail_igdb_sync(run, reason)
    end
  rescue
    exception ->
      case Repo.get(SyncRun, id) do
        %SyncRun{} = run -> fail_igdb_sync(run, exception)
        nil -> :ok
      end
  end

  defp run_automatic_ai(run_id, source_ids, options) do
    case AI.configuration_status() do
      {:ok, %{mode: :auto}} ->
        :ok = update_igdb_progress(run_id, "automatic_ai_matching", %{})
        finish_automatic_ai(Keyword.put(options, :source_ids, source_ids))

      _review_or_disabled ->
        :ok
    end
  end

  defp finish_automatic_ai(options) do
    case AI.run_automatic(system_scope(), options) do
      {:ok, _counts} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Automatic AI matching could not finish after IGDB enrichment: #{Redactor.redact_inspect(reason)}"
        )
    end
  end

  defp complete_igdb_sync(run, counts) do
    run = Repo.get!(SyncRun, run.id)

    {:ok, run} =
      Repo.transact(fn ->
        run =
          run
          |> SyncRun.progress_changeset(%{
            status: :completed,
            finished_at: DateTime.utc_now(:second),
            discovered_count: counts.discovered_count,
            updated_count: counts.updated_count,
            matched_count: counts.matched_count,
            unmatched_count: counts.unmatched_count,
            failed_count: counts.failed_count,
            checkpoint: %{
              "step" => "complete",
              "covers_cached" => counts.cached_count,
              "screenshots_cached" => Map.get(counts, :screenshots_cached_count, 0),
              "screenshots_failed" => Map.get(counts, :screenshots_failed_count, 0),
              "partial_failures" => counts.failed_count
            }
          })
          |> Repo.update!()

        persist_partial_errors(run, "igdb_enrichment", Map.get(counts, :failures, []))
        {:ok, run}
      end)

    broadcast(run)
    run
  end

  defp maybe_start_compatibility(_run, false, _options), do: :ok

  defp maybe_start_compatibility(run, true, options) do
    case start_compatibility_sync(system_scope(), options) do
      {:ok, compatibility_run} ->
        checkpoint =
          Map.put(run.checkpoint || %{}, "compatibility_run_id", compatibility_run.id)

        run
        |> SyncRun.progress_changeset(%{checkpoint: checkpoint})
        |> Repo.update!()
        |> broadcast()

      {:error, :sync_in_progress} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Could not queue compatibility after IGDB enrichment: #{Redactor.redact_inspect(reason)}"
        )
    end
  rescue
    exception ->
      Logger.warning(
        "Could not queue compatibility after IGDB enrichment: #{safe_message(exception)}"
      )
  end

  defp fail_igdb_sync(run, reason) do
    run = Repo.get!(SyncRun, run.id)
    now = DateTime.utc_now(:second)
    error = normalize_igdb_error(reason)

    Repo.transact(fn ->
      {:ok, _sync_error} =
        %SyncError{}
        |> SyncError.changeset(%{
          sync_run_id: run.id,
          stage: "igdb_enrichment",
          kind: Atom.to_string(error.kind),
          message: error.message,
          retryable: error.retryable
        })
        |> Repo.insert()

      {:ok, failed_run} =
        run
        |> SyncRun.progress_changeset(%{
          status: :failed,
          finished_at: now,
          failed_count: 1,
          checkpoint: %{"step" => "failed", "kind" => Atom.to_string(error.kind)}
        })
        |> Repo.update()

      {:ok, failed_run}
    end)
    |> case do
      {:ok, failed_run} -> broadcast(failed_run)
      _error -> :ok
    end
  end

  defp execute_steam(id, client, client_options, enqueue_enrichment?) do
    run = Repo.get!(SyncRun, id)
    account = Repo.get!(ProviderAccount, run.provider_account_id)
    spec = account_sync_spec(:steam)
    run = begin_account_sync(run, account, spec)

    result =
      with {:ok, payload} <- Integrations.steam_credentials_for_sync(),
           {:ok, games} <- client.fetch_library(account, payload, client_options),
           :ok <- visible_library(games),
           {:ok, counts} <- Reconciler.reconcile(account, games) do
        {:ok, counts}
      end

    case result do
      {:ok, counts} -> complete_account_sync(run, account, counts, enqueue_enrichment?, spec)
      {:error, reason} -> fail_account_sync(run, account, reason, spec)
    end
  rescue
    exception ->
      case {Repo.get(SyncRun, id), Repo.get_by(ProviderAccount, id: run_account_id(id))} do
        {%SyncRun{} = run, %ProviderAccount{} = account} ->
          fail_account_sync(run, account, exception, account_sync_spec(:steam))

        _other ->
          :ok
      end
  end

  defp maybe_enqueue_enrichment(new_source_count, true, opts) when new_source_count > 0 do
    case Iri.Sync.Scheduler.enqueue_library_enrichment(opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Could not queue metadata enrichment after a library import: #{Redactor.redact_inspect(reason)}"
        )
    end
  end

  defp maybe_enqueue_enrichment(_new_source_count, _enqueue_enrichment?, _opts), do: :ok

  defp active_run?(account_id) do
    Repo.exists?(
      from run in SyncRun,
        where: run.provider_account_id == ^account_id and run.status in [:queued, :running]
    )
  end

  defp active_igdb_run? do
    Repo.exists?(
      from run in SyncRun,
        where: run.provider == :igdb and run.status in [:queued, :running]
    )
  end

  defp active_compatibility_run? do
    Repo.exists?(
      from run in SyncRun,
        where: run.stage == "steam_compatibility" and run.status in [:queued, :running]
    )
  end

  defp compatibility_error_message(reason), do: ErrorNormalizer.compatibility(reason)

  defp load_enrichment_account(nil), do: {:ok, nil}
  defp load_enrichment_account(""), do: {:ok, nil}

  defp load_enrichment_account(provider_account_id) do
    case Repo.get(ProviderAccount, provider_account_id) do
      %ProviderAccount{provider: provider, enabled: true} = account
      when provider in [:steam, :gog] ->
        {:ok, account}

      other ->
        other
    end
  end

  defp visible_library([]), do: {:error, :library_not_visible}
  defp visible_library(games) when is_list(games), do: :ok
  defp visible_library(_games), do: {:error, :invalid_game_payload}

  defp run_account_id(id) do
    case Repo.get(SyncRun, id) do
      %SyncRun{provider_account_id: account_id} -> account_id
      nil -> nil
    end
  end

  defp normalize_sync_error(reason), do: ErrorNormalizer.steam(reason)
  defp normalize_gog_error(reason), do: ErrorNormalizer.gog(reason)
  defp normalize_xbox_error(reason), do: ErrorNormalizer.xbox(reason)
  defp normalize_igdb_error(reason), do: ErrorNormalizer.igdb(reason)

  defp update_igdb_progress(run_id, step, details) do
    case Repo.get(SyncRun, run_id) do
      %SyncRun{} = run ->
        checkpoint = Map.merge(%{"step" => step}, details)

        run =
          run
          |> SyncRun.progress_changeset(%{status: :running, checkpoint: checkpoint})
          |> Repo.update!()

        broadcast(run)
        :ok

      nil ->
        {:error, :sync_run_not_found}
    end
  end

  defp execute_dummy(id) do
    run = Repo.get!(SyncRun, id)
    now = DateTime.utc_now(:second)

    run =
      run
      |> SyncRun.progress_changeset(%{
        status: :running,
        started_at: now,
        checkpoint: %{"step" => "checking_persistence"}
      })
      |> Repo.update!()

    broadcast(run)

    run =
      run
      |> SyncRun.progress_changeset(%{
        status: :completed,
        finished_at: DateTime.utc_now(:second),
        checkpoint: %{"step" => "complete", "durable" => true}
      })
      |> Repo.update!()

    broadcast(run)
  rescue
    exception -> persist_failure(id, exception)
  end

  defp persist_failure(id, exception) do
    case Repo.get(SyncRun, id) do
      nil ->
        :ok

      run ->
        message = safe_message(exception)

        {:ok, run} =
          Repo.transact(fn ->
            insert_sync_error!(run, "unexpected", message, true)

            failed_run =
              run
              |> SyncRun.progress_changeset(%{
                status: :failed,
                finished_at: DateTime.utc_now(:second),
                failed_count: 1,
                checkpoint: %{"step" => "failed"}
              })
              |> Repo.update!()

            {:ok, failed_run}
          end)

        broadcast(run)
    end
  end

  defp fail_to_start(run, reason) do
    message = reason |> Redactor.redact_inspect() |> String.slice(0, 500)

    {:ok, run} =
      Repo.transact(fn ->
        insert_sync_error!(run, "task_start_failed", message, true)

        failed_run =
          run
          |> SyncRun.progress_changeset(%{
            status: :failed,
            finished_at: DateTime.utc_now(:second),
            failed_count: 1,
            checkpoint: %{"step" => "failed_to_start"}
          })
          |> Repo.update!()

        {:ok, failed_run}
      end)

    broadcast(run)
    {:error, :task_start_failed}
  end

  defp persist_partial_errors(run, stage, failures) do
    failures
    |> Enum.take(20)
    |> Enum.each(fn failure ->
      kind = Map.get(failure, :kind, "item_failed")
      message = Map.get(failure, :message, "An item could not be processed.")
      retryable? = Map.get(failure, :retryable, true)

      insert_sync_error!(
        %{run | stage: stage},
        kind |> to_string() |> String.slice(0, 100),
        message |> Redactor.redact() |> String.slice(0, 1_000),
        retryable?
      )
    end)
  end

  defp insert_sync_error!(run, kind, message, retryable?) do
    %SyncError{}
    |> SyncError.changeset(%{
      sync_run_id: run.id,
      stage: run.stage,
      kind: kind,
      message: message,
      retryable: retryable?
    })
    |> Repo.insert!()
  end

  defp load_optional_account(nil), do: {:ok, nil}
  defp load_optional_account(""), do: {:ok, nil}

  defp load_optional_account(id) do
    case Repo.get(ProviderAccount, id) do
      nil -> {:error, :provider_account_not_found}
      account -> {:ok, account}
    end
  end

  defp tap_success({:ok, value} = result, callback) do
    callback.(value)
    result
  end

  defp tap_success(result, _callback), do: result

  defp broadcast(run) do
    Phoenix.PubSub.broadcast(Iri.PubSub, @topic, {:sync_run_updated, run.id})
  end

  defp safe_message(exception) do
    exception
    |> Redactor.exception_message()
    |> String.slice(0, 500)
  end

  defp authorize_admin(%Scope{} = scope) do
    if Scope.admin?(scope), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_user(%Scope{user: %Iri.Accounts.User{}}), do: :ok
  defp authorize_user(_scope), do: {:error, :unauthorized}

  defp authorize_account_owner(%Scope{user: nil, role: :admin}, _id), do: :ok

  defp authorize_account_owner(%Scope{user: %Iri.Accounts.User{id: user_id}}, id) do
    if Repo.exists?(
         from account in ProviderAccount,
           where: account.id == ^id and account.owner_user_id == ^user_id
       ), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_account_owner(_scope, _id), do: {:error, :unauthorized}
end
