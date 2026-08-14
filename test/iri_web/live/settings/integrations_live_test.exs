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

defmodule IriWeb.Settings.IntegrationsLiveTest do
  use IriWeb.ConnCase

  import Iri.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Iri.Accounts.Scope
  alias Iri.Integrations
  alias Iri.Repo
  alias Iri.Sync.SyncRun

  test "every signed-in user can manage their own integrations", %{conn: conn} do
    viewer = viewer_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(viewer) |> live(~p"/settings/integrations")
    assert has_element?(view, "#connect-steam-form")
    assert has_element?(view, "#connect-gog-form")
    assert has_element?(view, "#connect-xbox-form")
    assert has_element?(view, "#connect-xbox-form input[disabled]")
    assert has_element?(view, "#connect-xbox-button[disabled]")
    assert has_element?(view, "#openxbl-api-key-setup a[href='https://xbl.io/']")
    assert has_element?(view, "#openxbl-api-key-setup code", "OPENXBL_API_KEY")
    assert has_element?(view, "#connected-libraries-heading", "Your libraries")
    assert has_element?(view, "#provider-accounts.divide-y")
    assert has_element?(view, "#other-imports-heading", "Other imports")
    assert has_element?(view, "section[aria-label='Connect a library']")

    assert has_element?(
             view,
             "#settings-navigation a.bg-teal-300[aria-current='page'][href='/settings/integrations']"
           )

    refute has_element?(view, "button[phx-click='sync_igdb']")
  end

  test "unconfigured Steam imports explain the operator setup", %{conn: conn} do
    configured_key = Application.fetch_env!(:iri, :steam_web_api_key)
    Application.delete_env(:iri, :steam_web_api_key)
    on_exit(fn -> Application.put_env(:iri, :steam_web_api_key, configured_key) end)

    viewer = viewer_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(viewer) |> live(~p"/settings/integrations")

    assert has_element?(view, "#connect-steam-form input[disabled]")
    assert has_element?(view, "#connect-steam-button[disabled]")

    assert has_element?(
             view,
             "#steam-api-key-setup a[href='https://steamcommunity.com/dev/apikey']"
           )

    assert has_element?(view, "#steam-api-key-setup code", "STEAM_WEB_API_KEY")
  end

  test "connects a public GOG profile and queues ownership", %{conn: conn} do
    user = viewer_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings/integrations")

    view
    |> form("#connect-gog-form", gog_connection_form: %{profile: "fixture-gog"})
    |> render_submit()

    Iri.DataCase.await_sync_tasks()
    assert has_element?(view, "#provider-accounts article", "Fixture GOG player")
    assert {:ok, [account]} = Integrations.list_provider_accounts(Scope.for_user(user))
    assert account.owner_user_id == user.id
  end

  test "owner can change sharing and remove a library", %{conn: conn} do
    user = viewer_user_fixture()

    {:ok, account} =
      Integrations.create_provider_account(Scope.for_user(user), %{
        provider: :steam,
        external_user_id: "76561198000000009",
        display_name: "Mine"
      })

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings/integrations")

    view
    |> form("#access-#{account.id}",
      access: %{account_id: account.id, sharing_policy: "everyone"}
    )
    |> render_change()

    assert Repo.reload!(account).sharing_policy == :everyone

    view |> element("#delete-account-#{account.id}") |> render_click()
    refute Repo.get(Iri.Integrations.ProviderAccount, account.id)
  end

  test "a linked Steam library can be selected as the personal playtime source", %{conn: conn} do
    user = viewer_user_fixture()

    {:ok, account} =
      Integrations.create_provider_account(Scope.for_user(user), %{
        provider: :steam,
        external_user_id: "76561198000000019",
        display_name: "Personal Steam"
      })

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings/integrations")
    assert has_element?(view, "#main-steam-account-#{account.id}")

    view |> element("#main-steam-account-#{account.id}") |> render_click()

    refute has_element?(view, "#main-steam-account-#{account.id}")
    assert has_element?(view, "#provider-accounts article", "Main")
    assert Repo.reload!(user).main_steam_account_id == account.id
  end

  test "admin sees global maintenance controls", %{conn: conn} do
    admin = admin_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/integrations")
    assert has_element?(view, "#enrich-new-games.bg-teal-300")
    assert has_element?(view, "#refresh-all-metadata.bg-teal-300")
    assert has_element?(view, "#refresh-all-compatibility.bg-teal-300")

    view |> element("#refresh-all-compatibility") |> render_click()
    Iri.DataCase.await_sync_tasks()

    run = Repo.get_by!(SyncRun, stage: "steam_compatibility")
    assert run.status == :completed
    assert run.checkpoint["force"]
  end
end
