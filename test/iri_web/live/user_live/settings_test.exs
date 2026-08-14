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

defmodule IriWeb.UserLive.SettingsTest do
  use IriWeb.ConnCase

  alias Iri.Accounts
  import Phoenix.LiveViewTest
  import Iri.AccountsFixtures

  describe "Settings page" do
    test "renders username, Steam, and password settings", %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/settings/account")

      assert page_title(lv) =~ "Account settings"
      assert has_element?(lv, "#username-form")
      assert has_element?(lv, "#sensitive-media-form")
      assert has_element?(lv, "#sensitive-media-form option[value='inherit']", "Server default")
      assert has_element?(lv, "#sensitive-media-form option[value='blur']", "Blur until revealed")
      assert has_element?(lv, "#steam-sign-in")
      assert has_element?(lv, "#password_form")
      assert has_element?(lv, "#account-role", "admin account")
      assert has_element?(lv, "#account-settings-header > #settings-navigation")

      assert has_element?(
               lv,
               "#settings-navigation[class~='order-first'][class~='sm:self-start']"
             )

      assert has_element?(
               lv,
               "#settings-navigation a.bg-teal-300[aria-current='page'][href='/settings/account']"
             )

      assert has_element?(lv, "#settings-navigation a[href='/settings/account']", "Account")

      assert has_element?(
               lv,
               "#settings-navigation a[href='/settings/integrations']",
               "Integrations"
             )
    end

    test "keeps admin-only settings out of a viewer's account page", %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> log_in_user(viewer_user_fixture())
        |> live(~p"/settings/account")

      assert has_element?(lv, "#settings-navigation a[href='/settings/account']")
      assert has_element?(lv, "#settings-navigation a[href='/settings/integrations']")
      refute has_element?(lv, "#settings-navigation a[href='/settings/accounts']")
      refute has_element?(lv, "#settings-navigation a[href='/settings/sync']")
      refute has_element?(lv, "#settings-navigation a[href='/settings/matches']")
      assert has_element?(lv, "#settings-nav-link[href='/settings/account']")
    end

    test "redirects if user is not logged in", %{conn: conn} do
      # An instance that already has an account sends anonymous visitors to log
      # in; a fresh instance sends them to registration instead.
      _existing = viewer_user_fixture()

      assert {:error, redirect} = live(conn, ~p"/settings/account")
      assert {:redirect, %{to: path}} = redirect
      assert path == ~p"/users/log-in"
    end
  end

  describe "sensitive media form" do
    test "stores a per-user override", %{conn: conn} do
      user = viewer_user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/settings/account")

      lv
      |> form("#sensitive-media-form", user: %{sensitive_media_mode: "allow"})
      |> render_submit()

      assert Accounts.get_user!(user.id).sensitive_media_mode == :allow
      assert has_element?(lv, "#sensitive-media-form option[value='allow'][selected]")
    end
  end

  describe "username form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the username", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/settings/account")

      lv
      |> form("#username-form", user: %{username: "new_name"})
      |> render_submit()

      assert Accounts.get_user!(user.id).username == "new_name"
    end

    test "renders invalid username errors", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/account")

      result =
        lv
        |> form("#username-form", user: %{username: "with spaces"})
        |> render_submit()

      assert result =~ "may only contain letters, numbers"
    end
  end

  describe "password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the local password", %{conn: conn, user: user} do
      password = "sixsix"
      {:ok, lv, _html} = live(conn, ~p"/settings/account")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "username" => user.username,
            "password" => password,
            "password_confirmation" => password
          }
        })

      render_submit(form)
      new_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_conn) == ~p"/settings/account"
      assert Accounts.get_user_by_username_and_password(user.username, password)
    end

    test "accepts six characters but rejects shorter passwords", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/account")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{"password" => "short", "password_confirmation" => "short"}
        })
        |> render_submit()

      assert result =~ "should be at least 6 character(s)"
    end
  end
end
