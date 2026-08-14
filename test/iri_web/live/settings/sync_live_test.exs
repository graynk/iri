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

defmodule IriWeb.Settings.SyncLiveTest do
  use IriWeb.ConnCase

  import Iri.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Iri.Repo
  alias Iri.Sync.{SyncError, SyncRun}

  test "displays sync timestamps in the configured timezone", %{conn: conn} do
    original_time_zone = Application.get_env(:iri, :time_zone)
    Application.put_env(:iri, :time_zone, "Europe/Berlin")
    on_exit(fn -> Application.put_env(:iri, :time_zone, original_time_zone) end)

    %SyncRun{inserted_at: ~U[2026-07-15 12:00:00Z]}
    |> SyncRun.create_changeset(%{
      provider: :steam,
      stage: "steam_compatibility",
      status: :completed
    })
    |> Repo.insert!()

    admin = admin_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/sync")

    assert has_element?(view, "#sync-runs time", "2026-07-15 14:00:00 CEST")
  end

  test "admin can inspect durable sync runs without development-only controls", %{conn: conn} do
    admin = admin_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/sync")

    assert has_element?(view, "ul#scheduled-tasks")
    assert has_element?(view, "ul#sync-runs")
    refute has_element?(view, "#dummy-sync-form")
  end

  test "shows persisted progress for a running compatibility refresh", %{conn: conn} do
    run =
      %SyncRun{}
      |> SyncRun.create_changeset(%{
        provider: :steam,
        stage: "steam_compatibility",
        status: :running,
        checkpoint: %{"step" => "fetching_protondb", "processed" => 250, "total" => 1_000}
      })
      |> Repo.insert!()

    admin = admin_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/sync")

    assert has_element?(
             view,
             "#sync-progress-#{run.id}[role='progressbar'][aria-valuenow='250'][aria-valuemax='1000']"
           )

    assert has_element?(
             view,
             "#sync-progress-#{run.id} [data-role='progress-count']",
             "250 of 1000 checks"
           )

    assert has_element?(view, "#sync-progress-#{run.id} [data-role='progress-phase']", "ProtonDB")
    assert has_element?(view, "#sync-progress-#{run.id} [data-role='progress-fill'].bg-teal-400")

    refute has_element?(
             view,
             "#sync-progress-#{run.id} [data-role='progress-fill'].bg-gradient-to-r"
           )

    assert has_element?(view, "#sync-progress-#{run.id}", "25%")
  end

  test "names the Steam compatibility phase by the data it fetches", %{conn: conn} do
    run =
      %SyncRun{}
      |> SyncRun.create_changeset(%{
        provider: :steam,
        stage: "steam_compatibility",
        status: :running,
        checkpoint: %{
          "step" => "fetching_steam_details",
          "processed" => 1,
          "total" => 2
        }
      })
      |> Repo.insert!()

    admin = admin_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/sync")

    assert has_element?(
             view,
             "#sync-progress-#{run.id} [data-role='progress-phase']",
             "Steam Store details"
           )
  end

  test "names Deck compatibility as its own phase", %{conn: conn} do
    run =
      %SyncRun{}
      |> SyncRun.create_changeset(%{
        provider: :steam,
        stage: "steam_compatibility",
        status: :running,
        checkpoint: %{
          "step" => "fetching_deck_compatibility",
          "processed" => 2,
          "total" => 4
        }
      })
      |> Repo.insert!()

    admin = admin_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/sync")

    assert has_element?(
             view,
             "#sync-progress-#{run.id} [data-role='progress-phase']",
             "Steam Deck compatibility"
           )
  end

  test "shows automatic AI matching as part of a running enrichment", %{conn: conn} do
    %SyncRun{}
    |> SyncRun.create_changeset(%{
      provider: :igdb,
      stage: "igdb_enrichment",
      status: :running,
      checkpoint: %{"step" => "automatic_ai_matching"}
    })
    |> Repo.insert!()

    admin = admin_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/sync")

    assert has_element?(
             view,
             "#sync-runs [data-role='running-step']",
             "Resolving ambiguous titles with AI"
           )
  end

  test "shows the persisted result and diagnostic for a failed run", %{conn: conn} do
    run =
      %SyncRun{}
      |> SyncRun.create_changeset(%{
        provider: :xbox,
        stage: "xbox_title_history",
        status: :failed
      })
      |> Repo.insert!()

    %SyncError{}
    |> SyncError.changeset(%{
      sync_run_id: run.id,
      stage: run.stage,
      kind: "rate_limited",
      message: "OpenXBL asked Iri to retry later.",
      retryable: true
    })
    |> Repo.insert!()

    admin = admin_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/sync")

    assert has_element?(view, "#sync-runs details", "1 error during this run")
    assert has_element?(view, "#sync-runs details", "OpenXBL asked Iri to retry later.")
    refute has_element?(view, "#sync-runs [data-role='missing-diagnostic']")
  end

  test "renders legacy non-UTF-8 diagnostics without crashing the LiveView", %{conn: conn} do
    run =
      %SyncRun{}
      |> SyncRun.create_changeset(%{
        provider: :steam,
        stage: "steam_compatibility",
        status: :completed
      })
      |> Repo.insert!()

    now = DateTime.utc_now(:second)

    Repo.insert_all(SyncError, [
      %{
        sync_run_id: run.id,
        stage: "steam_compatibility",
        kind: "item_failed",
        message: <<"STEAM returned HTTP 429: ", 31, 139, 8, 0>>,
        retryable: true,
        inserted_at: now,
        updated_at: now
      }
    ])

    admin = admin_user_fixture()
    {:ok, view, html} = conn |> log_in_user(admin) |> live(~p"/settings/sync")

    assert String.valid?(html)

    assert has_element?(
             view,
             "#sync-runs li",
             "STEAM returned HTTP 429: [non-text data omitted]"
           )
  end
end
