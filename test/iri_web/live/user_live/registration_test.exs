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

defmodule IriWeb.UserLive.RegistrationTest do
  use IriWeb.ConnCase

  import Phoenix.LiveViewTest
  import Iri.AccountsFixtures

  setup do
    previous = Application.get_env(:iri, :mode)
    Application.put_env(:iri, :mode, :public)
    on_exit(fn -> Application.put_env(:iri, :mode, previous) end)
  end

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/register")

      assert page_title(lv) =~ "Register"
      assert html =~ "Register"
      assert html =~ "Log in"
      assert has_element?(lv, "#first-user-admin-note")
      assert has_element?(lv, "#registration_form button.bg-teal-300", "Create account")
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/library")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"username" => "with spaces"})

      assert result =~ "Register"
      assert result =~ "may only contain letters, numbers"

      assert has_element?(
               lv,
               "#user_username[aria-invalid='true'][aria-describedby='user_username-errors']"
             )

      assert has_element?(lv, "#user_username-errors", "may only contain letters, numbers")
    end
  end

  describe "register user" do
    test "creates account and logs in without asking for credentials again", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      attrs = valid_user_attributes()
      form = form(lv, "#registration_form", user: attrs)

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/library"
      assert get_session(conn, :user_token)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Account created. Welcome to IRI!"
    end

    test "renders errors for duplicated username", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{username: "test_user"})

      result =
        lv
        |> form("#registration_form",
          user: %{
            "username" => user.username,
            "password" => valid_user_password(),
            "password_confirmation" => valid_user_password()
          }
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Log in"
    end
  end
end
