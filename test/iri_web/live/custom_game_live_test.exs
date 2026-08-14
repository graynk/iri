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

defmodule IriWeb.CustomGameLiveTest do
  use IriWeb.ConnCase

  import Iri.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Iri.Accounts.Scope
  alias Iri.Integrations.Custom
  alias Iri.Library.Game
  alias Iri.Repo

  test "a user can replace a custom IGDB selection through the rich search UI", %{conn: conn} do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)
    assert {:ok, %{added: 1}} = Custom.add_ids(scope, [10])
    old_game = Repo.get_by!(Game, igdb_id: 10)

    {:ok, detail, _html} =
      conn |> log_in_user(user) |> live(~p"/games/#{old_game.slug}")

    # The owner's "Fix match" button routes to the replace search UI.
    assert has_element?(detail, "#fix-match")

    assert {:error, {:live_redirect, %{to: to}}} =
             detail |> element("#fix-match") |> render_click()

    assert to == "/library/add?replace=#{old_game.id}"

    {:ok, view, _html} =
      conn |> recycle() |> log_in_user(user) |> live(~p"/library/add?replace=#{old_game.id}")

    assert has_element?(view, "#igdb-game-search")
    refute has_element?(view, "#steam-manual-import")
    refute has_element?(view, "#igdb-batch-import")

    view
    |> form("#igdb-game-search", search: %{query: "The Legend of Zelda"})
    |> render_submit()

    assert has_element?(view, "#replace-custom-game-90001", "Use this game")
    view |> element("#replace-custom-game-90001") |> render_click()

    target = Repo.get_by!(Game, igdb_id: 90_001)
    assert_redirect(view, ~p"/games/#{target.slug}")
  end

  test "the add-games page offers a manual Steam AppID fallback", %{conn: conn} do
    user = viewer_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/library/add")

    assert has_element?(view, "#add-games-header")
    refute has_element?(view, "#add-games-header a")
    assert has_element?(view, "#steam-manual-import")
    assert has_element?(view, "#steam-manual-import-form")
    assert has_element?(view, "#steam-manual-app-id[inputmode='numeric']")
  end
end
