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

defmodule IriWeb.ProviderImportLiveTest do
  use IriWeb.ConnCase

  import Iri.AccountsFixtures
  import Phoenix.LiveViewTest

  test "custom game page searches IGDB and adds a result", %{conn: conn} do
    user = viewer_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/library/add")
    assert has_element?(view, "#igdb-game-search")
    assert has_element?(view, "#igdb-game-search-query-clearable[phx-hook='ClearableSearch']")
    assert has_element?(view, "#igdb-game-search-query-clear[disabled]")

    view |> form("#igdb-game-search", search: %{query: "Fixture"}) |> render_submit()
    refute has_element?(view, "#igdb-game-search-query-clear[disabled]")
    assert has_element?(view, "#igdb-search-results article")
    assert has_element?(view, "#igdb-result-90001 [data-role='developer']", "Fixture Studio")

    assert has_element?(
             view,
             "#igdb-result-90001 [data-role='summary']",
             "A searchable fixture game used to identify this result."
           )

    view |> element("#igdb-search-results button", "Add") |> render_click()
    assert has_element?(view, "#igdb-result-90001 button", "Remove")
  end

  test "manual provider pages expose file-based helpers", %{conn: conn} do
    user = viewer_user_fixture()
    conn = log_in_user(conn, user)

    {:ok, epic, _html} = live(conn, ~p"/settings/integrations/epic/import")
    assert has_element?(epic, "#legendary-upload-form input[type='file']")

    assert has_element?(
             epic,
             "#legendary-installation[href='https://github.com/legendary-gl/legendary']"
           )

    {:ok, psn, _html} =
      live(build_conn() |> log_in_user(user), ~p"/settings/integrations/psn/import")

    assert has_element?(psn, "a[href='/helpers/psn-collector.js'][download]")

    assert has_element?(
             psn,
             "a[href='https://library.playstation.com/recently-purchased']"
           )

    assert has_element?(psn, "#psn-response-form input[type='file']")
    refute has_element?(psn, "#psn-response-form input[name='psn[account_name]']")
    refute has_element?(psn, "#psn-response-form textarea")
  end

  test "PlayStation upload derives the account from the collector file", %{conn: conn} do
    user = viewer_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings/integrations/psn/import")

    payload =
      Jason.encode!(%{
        "schema" => "iri-psn-export/v3",
        "account" => %{"id" => "123456789", "online_id" => "FixturePlayer"},
        "datasets" => [
          %{
            "kind" => "played",
            "items" => [%{"concept_id" => "10001", "name" => "Astro Bot"}]
          }
        ]
      })

    upload =
      file_input(view, "#psn-response-form", :psn_export, [
        %{name: "iri-psn-games.json", content: payload, type: "application/json"}
      ])

    render_upload(upload, "iri-psn-games.json")
    view |> form("#psn-response-form") |> render_submit()

    assert has_element?(view, "#psn-preview", "FixturePlayer: 1 games")
  end

  test "only an administrator can open account management", %{conn: conn} do
    admin = admin_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/accounts")
    assert has_element?(view, "#admin-create-user-form")
    assert has_element?(view, "ul#users > li")

    viewer = viewer_user_fixture()

    assert {:error, {:redirect, %{to: "/", flash: _}}} =
             build_conn() |> log_in_user(viewer) |> live(~p"/settings/accounts")
  end
end
