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

defmodule IriWeb.UserLive.LoginTest do
  use IriWeb.ConnCase

  import Phoenix.LiveViewTest
  import Iri.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      assert page_title(lv) =~ "Log in"
      assert has_element?(lv, "#login_form_password")
      assert has_element?(lv, "a", "Sign up")
      assert has_element?(lv, "#first-user-admin-note")
      assert has_element?(lv, "a.underline", "Sign up")
      assert has_element?(lv, "#login_form_password button.bg-teal-300", "Log in")
      assert has_element?(lv, "#theme-switcher[data-theme-cookie='iri-theme']")

      assert has_element?(
               lv,
               "#theme-switcher > button.cursor-pointer[class~='hover:bg-teal-400/10'][aria-controls='theme-options'][aria-expanded='false']"
             )

      assert has_element?(lv, "#theme-options[role='group'][aria-label='Choose a theme']")

      for theme <- ~w(dark light vapor high-contrast ai-slop) do
        assert has_element?(
                 lv,
                 "#theme-options button[data-theme-option='#{theme}'][aria-pressed='false']"
               )

        assert has_element?(
                 lv,
                 "#theme-options button.cursor-pointer[data-theme-option='#{theme}']"
               )
      end

      refute has_element?(lv, "#theme-options[role='menu']")
      refute has_element?(lv, "button", "Log in and stay logged in")
      refute has_element?(lv, "button", "Log in only this time")
    end
  end

  describe "user login - password" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password",
          user: %{username: user.username, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/library"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password", user: %{username: "missing", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the Register button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Sign up")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/register")

      assert login_html =~ "Register"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with username filled in", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#login_form_password")
      assert has_element?(lv, "#user_username[value='#{user.username}'][readonly]")
      refute has_element?(lv, "main a", "Sign up")
    end
  end
end
