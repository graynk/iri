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

defmodule Iri.SyncTest do
  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Accounts.Scope
  alias Iri.AI.MatchReview
  alias Iri.Integrations
  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.LibraryItem
  alias Iri.Sync
  alias Iri.Sync.AccountSyncClientStub
  alias Iri.Sync.{Schedule, ScheduledTask, Scheduler, SyncError, SyncRun}

  test "persists a dummy run through queued, running, and completed states" do
    scope = admin_user_fixture() |> Scope.for_user()
    assert :ok = Sync.subscribe(scope)
    assert {:ok, queued} = Sync.start_dummy_sync(scope)
    assert queued.status == :queued

    completed = wait_for_status(queued.id, :completed)

    assert completed.started_at
    assert completed.finished_at
    assert completed.checkpoint == %{"durable" => true, "step" => "complete"}
    assert completed.failed_count == 0
  end

  test "viewer cannot inspect or start sync runs" do
    scope = viewer_user_fixture() |> Scope.for_user()

    assert {:error, :unauthorized} = Sync.list_recent_runs(scope)
    assert {:error, :unauthorized} = Sync.start_dummy_sync(scope)
  end

  test "records an expired worker lease as a retryable failed run" do
    expired_at = DateTime.add(DateTime.utc_now(:second), -1, :second)

    run =
      %SyncRun{}
      |> SyncRun.create_changeset(%{
        provider: :steam,
        stage: "steam_ownership",
        status: :running,
        checkpoint: %{"step" => "fetching_owned_games"},
        lease_expires_at: expired_at
      })
      |> Repo.insert!()

    assert :ok = Sync.recover_expired_runs()

    assert %SyncRun{status: :failed, checkpoint: %{"step" => "expired"}} =
             Repo.get!(SyncRun, run.id)

    assert %SyncError{kind: "lease_expired", retryable: true} =
             Repo.one!(from error in SyncError, where: error.sync_run_id == ^run.id)
  end

  test "runs a durable Steam ownership sync" do
    scope = admin_user_fixture() |> Scope.for_user()

    assert {:ok, account} =
             Integrations.create_provider_account(scope, %{
               "provider" => "steam",
               "external_user_id" => "76561198000000001",
               "display_name" => "Fixture player"
             })

    assert :ok = Sync.subscribe(scope)
    assert {:ok, queued} = Sync.start_steam_sync(scope, account.id)

    completed = wait_for_status(queued.id, :completed)
    assert completed.discovered_count == 2
    assert completed.inserted_count == 2
    assert completed.checkpoint == %{"new_sources" => 2, "step" => "complete"}
    assert Repo.aggregate(LibraryItem, :count) == 2

    queued_enrichment =
      Repo.get_by!(ScheduledTask, kind: "pending_library_enrichment")

    assert queued_enrichment.status == :idle
    assert queued_enrichment.compatibility_requested
    assert DateTime.compare(queued_enrichment.next_run_at, DateTime.utc_now(:second)) != :gt
  end

  test "runs a durable GOG public-profile ownership sync" do
    scope = admin_user_fixture() |> Scope.for_user()

    assert {:ok, %{account: account}} =
             Integrations.connect_gog(scope, %{"profile" => "fixture-gog"})

    assert :ok = Sync.subscribe(scope)
    assert {:ok, queued} = Sync.start_gog_sync(scope, account.id)

    completed = wait_for_status(queued.id, :completed)
    assert completed.discovered_count == 2
    assert completed.inserted_count == 2
    assert completed.checkpoint == %{"new_sources" => 2, "step" => "complete"}
    assert Repo.aggregate(LibraryItem, :count) == 2

    queued_enrichment =
      Repo.get_by!(ScheduledTask, kind: "pending_library_enrichment")

    refute queued_enrichment.compatibility_requested

    assert {:ok, repeated} = Sync.start_gog_sync(scope, account.id)

    assert %SyncRun{
             status: :completed,
             inserted_count: 0,
             checkpoint: %{"new_sources" => 0, "step" => "complete"}
           } = wait_for_status(repeated.id, :completed)

    refreshed_account = Repo.get!(ProviderAccount, account.id)
    assert refreshed_account.sync_status == "ready"
  end

  test "a failed GOG sync moves both the run and account into an error state" do
    scope = admin_user_fixture() |> Scope.for_user()

    assert {:ok, %{account: account}} =
             Integrations.connect_gog(scope, %{"profile" => "fixture-gog"})

    assert :ok = Sync.subscribe(scope)

    assert {:ok, queued} =
             Sync.start_gog_sync(scope, account.id,
               client: Iri.Integrations.GOG.FailingClientStub
             )

    assert %SyncRun{
             status: :failed,
             checkpoint: %{"kind" => "invalid_page_count", "step" => "failed"}
           } = wait_for_status(queued.id, :failed)

    assert %SyncError{
             stage: "gog_ownership",
             kind: "invalid_page_count",
             message: "GOG returned invalid pagination metadata.",
             retryable: false
           } = Repo.get_by!(SyncError, sync_run_id: queued.id)

    assert Repo.get!(ProviderAccount, account.id).sync_status == "error"
  end

  test "an empty Steam response fails without removing existing ownership" do
    scope = admin_user_fixture() |> Scope.for_user()

    assert {:ok, account} =
             Integrations.create_provider_account(scope, %{
               "provider" => "steam",
               "external_user_id" => "76561198000000001",
               "display_name" => "Fixture player"
             })

    assert :ok = Sync.subscribe(scope)
    assert {:ok, first_run} = Sync.start_steam_sync(scope, account.id)
    assert %SyncRun{status: :completed} = wait_for_status(first_run.id, :completed)
    assert Repo.aggregate(LibraryItem, :count) == 2

    assert {:ok, empty_run} =
             Sync.start_steam_sync(scope, account.id,
               client: Iri.Integrations.Steam.EmptyClientStub
             )

    assert %SyncRun{
             status: :failed,
             checkpoint: %{"kind" => "library_not_visible", "step" => "failed"}
           } = wait_for_status(empty_run.id, :failed)

    assert %SyncError{
             stage: "steam_ownership",
             kind: "library_not_visible",
             message: "Steam returned no games. Profile and Game Details must both be public.",
             retryable: false
           } = Repo.get_by!(SyncError, sync_run_id: empty_run.id)

    assert Repo.aggregate(from(item in LibraryItem, where: is_nil(item.removed_at)), :count) == 2
  end

  test "runs a durable Xbox title-history sync" do
    configure_openxbl_key()
    scope = admin_user_fixture() |> Scope.for_user()
    account = create_account(scope, :xbox, "xuid-42")

    assert :ok = Sync.subscribe(scope)

    assert {:ok, queued} =
             Sync.start_xbox_sync(scope, account.id, client: AccountSyncClientStub)

    completed = wait_for_status(queued.id, :completed)

    assert completed.provider == :xbox
    assert completed.stage == "xbox_title_history"
    assert completed.discovered_count == 1
    assert completed.inserted_count == 1
    assert completed.updated_count == 0
    assert completed.removed_count == 0
    assert completed.checkpoint == %{"step" => "complete"}

    assert %ProviderAccount{sync_status: "ready"} = Repo.get!(ProviderAccount, account.id)

    queued_enrichment =
      Repo.get_by!(ScheduledTask, kind: "pending_library_enrichment")

    refute queued_enrichment.compatibility_requested
  end

  test "account sync entry points preserve mismatch and disabled-account errors" do
    scope = admin_user_fixture() |> Scope.for_user()

    mismatch_accounts = %{
      steam: create_account(scope, :gog, "mismatch-gog"),
      gog: create_account(scope, :xbox, "mismatch-xbox"),
      xbox: create_account(scope, :steam, "mismatch-steam")
    }

    Enum.each([:steam, :gog, :xbox], fn provider ->
      account = Map.fetch!(mismatch_accounts, provider)

      assert {:error, mismatch_error(provider)} ==
               start_account_sync(provider, scope, account.id, enqueue_enrichment: false)
    end)

    Enum.each([:steam, :gog, :xbox], fn provider ->
      account = create_account(scope, provider, "disabled-#{provider}")

      account
      |> ProviderAccount.changeset(%{enabled: false})
      |> Repo.update!()

      assert {:error, mismatch_error(provider)} ==
               start_account_sync(provider, scope, account.id, enqueue_enrichment: false)
    end)
  end

  test "account sync entry points reject active runs and non-owners" do
    owner_scope = admin_user_fixture() |> Scope.for_user()
    other_scope = admin_user_fixture() |> Scope.for_user()

    Enum.each([:steam, :gog, :xbox], fn provider ->
      account = create_account(owner_scope, provider, "active-#{provider}")

      %SyncRun{}
      |> SyncRun.create_changeset(%{
        provider_account_id: account.id,
        provider: provider,
        stage: sync_stage(provider),
        status: :queued,
        checkpoint: %{"step" => "queued"},
        lease_expires_at: DateTime.add(DateTime.utc_now(:second), 60, :second)
      })
      |> Repo.insert!()

      assert {:error, :sync_in_progress} ==
               start_account_sync(provider, owner_scope, account.id, enqueue_enrichment: false)

      assert {:error, :unauthorized} ==
               start_account_sync(provider, other_scope, account.id, enqueue_enrichment: false)
    end)
  end

  test "account syncs expose their provider-specific running transitions" do
    configure_openxbl_key()
    scope = admin_user_fixture() |> Scope.for_user()
    assert :ok = Sync.subscribe(scope)

    Enum.each([:steam, :gog, :xbox], fn provider ->
      account = create_account(scope, provider, "transition-#{provider}")

      assert {:ok, queued} =
               start_account_sync(provider, scope, account.id,
                 client: AccountSyncClientStub,
                 client_options: [mode: :block, test_pid: self()],
                 enqueue_enrichment: false
               )

      assert queued.provider == provider
      assert queued.stage == sync_stage(provider)
      assert queued.status == :queued
      assert queued.checkpoint == %{"step" => "queued"}
      assert queued.lease_expires_at

      assert_receive {:account_sync_fetching, ^provider, task_pid}

      assert %SyncRun{
               status: :running,
               checkpoint: %{"step" => running_step}
             } = Repo.get!(SyncRun, queued.id)

      assert running_step == running_step(provider)

      assert %ProviderAccount{sync_status: "syncing"} = Repo.get!(ProviderAccount, account.id)
      send(task_pid, :release_account_sync)

      completed = wait_for_status(queued.id, :completed)
      assert completed.checkpoint == completion_checkpoint(provider, 1)
      assert Repo.get!(ProviderAccount, account.id).sync_status == "ready"
    end)
  end

  test "account sync failures retain provider-specific normalization and checkpoints" do
    configure_openxbl_key()
    scope = admin_user_fixture() |> Scope.for_user()
    assert :ok = Sync.subscribe(scope)

    cases = [
      {:steam, :invalid_game_payload, "invalid_game_payload",
       "Steam sync failed while validating the returned library."},
      {:gog, :invalid_page_count, "invalid_page_count",
       "GOG returned invalid pagination metadata."},
      {:xbox, :invalid_provider_credential, "authentication",
       "Reconnect this Xbox account before syncing it again."}
    ]

    Enum.each(cases, fn {provider, reason, kind, message} ->
      account = create_account(scope, provider, "failure-#{provider}")

      assert {:ok, queued} =
               start_account_sync(provider, scope, account.id,
                 client: AccountSyncClientStub,
                 client_options: [mode: {:error, reason}],
                 enqueue_enrichment: false
               )

      failed = wait_for_status(queued.id, :failed)
      assert failed.checkpoint == failure_checkpoint(provider, kind)
      assert failed.failed_count == 1

      assert %SyncError{
               stage: stage,
               kind: ^kind,
               message: ^message,
               retryable: false
             } = Repo.get_by!(SyncError, sync_run_id: queued.id)

      assert stage == sync_stage(provider)
      assert Repo.get!(ProviderAccount, account.id).sync_status == "error"
    end)
  end

  test "account sync exceptions remain retryable unexpected failures" do
    configure_openxbl_key()
    scope = admin_user_fixture() |> Scope.for_user()
    assert :ok = Sync.subscribe(scope)

    Enum.each([:steam, :gog, :xbox], fn provider ->
      account = create_account(scope, provider, "exception-#{provider}")
      message = "#{provider} sync exploded"

      assert {:ok, queued} =
               start_account_sync(provider, scope, account.id,
                 client: AccountSyncClientStub,
                 client_options: [mode: {:raise, message}],
                 enqueue_enrichment: false
               )

      failed = wait_for_status(queued.id, :failed)
      assert failed.checkpoint == failure_checkpoint(provider, "unexpected")

      assert %SyncError{
               stage: stage,
               kind: "unexpected",
               retryable: true
             } = error = Repo.get_by!(SyncError, sync_run_id: queued.id)

      assert stage == sync_stage(provider)
      assert error.message =~ message
    end)
  end

  test "Steam and GOG enrichment is gated by new global sources, not new account items" do
    scope = admin_user_fixture() |> Scope.for_user()
    assert :ok = Sync.subscribe(scope)

    Enum.each([:steam, :gog], fn provider ->
      first = create_account(scope, provider, "first-#{provider}")
      second = create_account(scope, provider, "second-#{provider}")

      assert {:ok, first_run} =
               start_account_sync(provider, scope, first.id,
                 client: AccountSyncClientStub,
                 enqueue_enrichment: false
               )

      assert %SyncRun{status: :completed} = wait_for_status(first_run.id, :completed)

      assert {:ok, second_run} =
               start_account_sync(provider, scope, second.id, client: AccountSyncClientStub)

      assert %SyncRun{
               status: :completed,
               inserted_count: 1,
               checkpoint: %{"new_sources" => 0, "step" => "complete"}
             } = wait_for_status(second_run.id, :completed)
    end)

    refute Repo.get_by(ScheduledTask, kind: "pending_library_enrichment")
  end

  test "runs a durable Steam compatibility refresh" do
    scope = admin_user_fixture() |> Scope.for_user()

    assert {:ok, account} =
             Integrations.create_provider_account(scope, %{
               "provider" => "steam",
               "external_user_id" => "76561198000000001",
               "display_name" => "Fixture player"
             })

    assert :ok = Sync.subscribe(scope)
    assert {:ok, ownership_run} = Sync.start_steam_sync(scope, account.id)
    assert %SyncRun{status: :completed} = wait_for_status(ownership_run.id, :completed)

    assert {:ok, queued} =
             Sync.start_compatibility_sync(scope,
               client: Iri.Integrations.Steam.StoreClientStub,
               client_options: [test_pid: self()],
               sync_options: [throttle_ms: 0]
             )

    completed = wait_for_status(queued.id, :completed)
    assert completed.discovered_count == 2
    assert completed.updated_count == 2
    assert completed.failed_count == 0
  end

  test "persists details for partial compatibility failures" do
    scope = admin_user_fixture() |> Scope.for_user()

    assert {:ok, account} =
             Integrations.create_provider_account(scope, %{
               "provider" => "steam",
               "external_user_id" => "76561198000000003",
               "display_name" => "Fixture player"
             })

    assert :ok = Sync.subscribe(scope)
    assert {:ok, ownership_run} = Sync.start_steam_sync(scope, account.id)
    assert %SyncRun{status: :completed} = wait_for_status(ownership_run.id, :completed)

    assert {:ok, queued} =
             Sync.start_compatibility_sync(scope,
               client: Iri.Integrations.Steam.StoreFailingClientStub,
               sync_options: [throttle_ms: 0]
             )

    completed = wait_for_status(queued.id, :completed)
    assert completed.failed_count == 2

    errors = Repo.all(from error in SyncError, where: error.sync_run_id == ^completed.id)
    assert length(errors) == 2
    assert Enum.all?(errors, &(&1.kind == "item_failed" and &1.retryable))
    assert Enum.all?(errors, &String.contains?(&1.message, "fixture store connection closed"))
  end

  test "incremental IGDB enrichment can queue compatibility after it completes" do
    scope = admin_user_fixture() |> Scope.for_user()

    assert :ok = Sync.subscribe(scope)

    assert {:ok, enrichment_run} =
             Sync.start_igdb_sync(scope,
               compatibility_after: true,
               compatibility_options: [
                 client: Iri.Integrations.Steam.StoreClientStub,
                 sync_options: [throttle_ms: 0]
               ]
             )

    assert %SyncRun{status: :completed} = wait_for_status(enrichment_run.id, :completed)

    compatibility_run = wait_for_stage_status("steam_compatibility", :completed)
    enrichment_run = Repo.get!(SyncRun, enrichment_run.id)

    assert enrichment_run.checkpoint["compatibility_run_id"] == compatibility_run.id
  end

  test "successful deterministic enrichment does not automatically queue AI reviews" do
    previous = Application.get_env(:iri, :ai_matching)

    Application.put_env(:iri, :ai_matching, %{
      provider: :openai_compatible,
      model: "fixture-model",
      base_url: "http://localhost:11434/v1",
      mode: :review
    })

    on_exit(fn -> Application.put_env(:iri, :ai_matching, previous) end)

    scope = admin_user_fixture() |> Scope.for_user()
    assert :ok = Sync.subscribe(scope)
    account = create_account(scope, :steam, "76561198000000444")

    assert {:ok, ownership_run} =
             Sync.start_steam_sync(scope, account.id,
               client: AccountSyncClientStub,
               enqueue_enrichment: false
             )

    assert %SyncRun{status: :completed} = wait_for_status(ownership_run.id, :completed)

    assert {:ok, enrichment_run} =
             Sync.start_igdb_sync(scope,
               client: Iri.Integrations.IGDB.UnmatchedClientStub
             )

    assert %SyncRun{status: :completed} = wait_for_status(enrichment_run.id, :completed)
    assert Repo.aggregate(MatchReview, :count) == 0
  end

  test "auto AI matching finishes after deterministic enrichment and before compatibility" do
    previous = Application.get_env(:iri, :ai_matching)

    Application.put_env(:iri, :ai_matching, %{
      provider: :openai_compatible,
      model: "fixture-model",
      base_url: "http://localhost:11434/v1",
      mode: :auto
    })

    on_exit(fn -> Application.put_env(:iri, :ai_matching, previous) end)

    scope = admin_user_fixture() |> Scope.for_user()
    assert :ok = Sync.subscribe(scope)
    account = create_account(scope, :steam, "76561198000000445")

    assert {:ok, ownership_run} =
             Sync.start_steam_sync(scope, account.id,
               client: AccountSyncClientStub,
               enqueue_enrichment: false
             )

    assert %SyncRun{status: :completed} = wait_for_status(ownership_run.id, :completed)

    assert {:ok, enrichment_run} =
             Sync.start_igdb_sync(scope,
               client: Iri.Integrations.IGDB.UnmatchedClientStub,
               automatic_ai_options: [adapter: Iri.AI.AdapterStub],
               compatibility_after: true,
               compatibility_options: [
                 client: Iri.Integrations.Steam.StoreClientStub,
                 sync_options: [throttle_ms: 0]
               ]
             )

    assert %SyncRun{status: :completed} = wait_for_status(enrichment_run.id, :completed)

    source = Repo.get_by!(Iri.Library.GameSource, provider: :steam, external_id: "90001")
    assert source.match_method == "ai_auto"
    assert %MatchReview{status: "applied"} = Repo.get_by!(MatchReview, game_source_id: source.id)
    assert %SyncRun{status: :completed} = wait_for_stage_status("steam_compatibility", :completed)
  end

  test "queued library enrichment runs IGDB before incremental compatibility" do
    assert :ok =
             Schedule.execute(
               "pending_library_enrichment",
               true,
               fn -> :ok end
             )

    runs = Repo.all(from run in SyncRun, order_by: [asc: run.id])

    assert Enum.map(runs, & &1.stage) == ["igdb_enrichment", "steam_compatibility"]
    assert Enum.all?(runs, &(&1.status == :completed))
  end

  test "queued imports rerun enrichment before requested compatibility" do
    now = DateTime.utc_now(:second)
    assert :ok = Scheduler.enqueue_library_enrichment(now, compatibility: true)
    assert [claimed] = Scheduler.claim_due_tasks(now)

    later = DateTime.add(now, 1, :second)
    assert :ok = Scheduler.enqueue_library_enrichment(later, compatibility: false)

    assert :ok =
             Schedule.execute(
               "pending_library_enrichment",
               claimed.compatibility_requested,
               fn -> :ok end
             )

    assert [%SyncRun{stage: "igdb_enrichment", status: :completed}] =
             Repo.all(from run in SyncRun, order_by: [asc: run.id])

    pending = Repo.get!(ScheduledTask, claimed.id)
    assert pending.rerun_requested
    assert pending.compatibility_requested

    assert :ok = Scheduler.complete(claimed, :ok)
    assert [second_claim] = Scheduler.claim_due_tasks(later)
    assert second_claim.compatibility_requested

    assert :ok =
             Schedule.execute(
               "pending_library_enrichment",
               second_claim.compatibility_requested,
               fn -> :ok end
             )

    assert Enum.map(Repo.all(from run in SyncRun, order_by: [asc: run.id]), & &1.stage) == [
             "igdb_enrichment",
             "igdb_enrichment",
             "steam_compatibility"
           ]
  end

  test "queued library enrichment skips compatibility unless a Steam import requested it" do
    assert :ok = Schedule.execute("pending_library_enrichment", false, fn -> :ok end)

    runs = Repo.all(from run in SyncRun, order_by: [asc: run.id])

    assert Enum.map(runs, & &1.stage) == ["igdb_enrichment"]
    assert Enum.all?(runs, &(&1.status == :completed))
  end

  test "nightly maintenance completes an SQLite integrity check" do
    assert :ok = Schedule.execute("nightly_library_maintenance", false, fn -> :ok end)
  end

  defp create_account(scope, provider, external_user_id) do
    assert {:ok, account} =
             Integrations.create_provider_account(scope, %{
               "provider" => Atom.to_string(provider),
               "external_user_id" => external_user_id,
               "display_name" => "#{provider} fixture"
             })

    account
  end

  defp start_account_sync(:steam, scope, account_id, options),
    do: Sync.start_steam_sync(scope, account_id, options)

  defp start_account_sync(:gog, scope, account_id, options),
    do: Sync.start_gog_sync(scope, account_id, options)

  defp start_account_sync(:xbox, scope, account_id, options),
    do: Sync.start_xbox_sync(scope, account_id, options)

  defp sync_stage(:steam), do: "steam_ownership"
  defp sync_stage(:gog), do: "gog_ownership"
  defp sync_stage(:xbox), do: "xbox_title_history"

  defp running_step(:steam), do: "fetching_owned_games"
  defp running_step(:gog), do: "fetching_owned_products"
  defp running_step(:xbox), do: "fetching_title_history"

  defp completion_checkpoint(provider, new_source_count) when provider in [:steam, :gog],
    do: %{"step" => "complete", "new_sources" => new_source_count}

  defp completion_checkpoint(:xbox, _new_source_count), do: %{"step" => "complete"}

  defp failure_checkpoint(provider, kind) when provider in [:steam, :gog],
    do: %{"step" => "failed", "kind" => kind}

  defp failure_checkpoint(:xbox, _kind), do: %{"step" => "failed"}

  defp mismatch_error(:steam), do: :not_a_steam_account
  defp mismatch_error(:gog), do: :not_a_gog_account
  defp mismatch_error(:xbox), do: :not_an_xbox_account

  defp configure_openxbl_key do
    previous = Application.get_env(:iri, :openxbl_api_key)
    Application.put_env(:iri, :openxbl_api_key, "consumer-secret")

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:iri, :openxbl_api_key)
      else
        Application.put_env(:iri, :openxbl_api_key, previous)
      end
    end)
  end

  defp wait_for_status(id, expected_status) do
    receive do
      {:sync_run_updated, ^id} ->
        run = Repo.get!(SyncRun, id)

        if run.status == expected_status do
          Iri.DataCase.await_sync_tasks()
          run
        else
          wait_for_status(id, expected_status)
        end
    after
      1_000 -> flunk("sync run #{id} did not reach #{expected_status}")
    end
  end

  defp wait_for_stage_status(stage, expected_status) do
    receive do
      {:sync_run_updated, id} ->
        run = Repo.get!(SyncRun, id)

        if run.stage == stage and run.status == expected_status do
          Iri.DataCase.await_sync_tasks()
          run
        else
          wait_for_stage_status(stage, expected_status)
        end
    after
      1_000 -> flunk("sync run for #{stage} did not reach #{expected_status}")
    end
  end
end
