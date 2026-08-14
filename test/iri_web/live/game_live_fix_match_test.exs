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

defmodule IriWeb.GameLiveFixMatchTest do
  use IriWeb.ConnCase

  import Iri.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Iri.Accounts.Scope
  alias Iri.Integrations.Custom
  alias Iri.Library.Game
  alias Iri.Repo

  test "an admin can fix the match of any game from its detail page", %{conn: conn} do
    admin = admin_user_fixture()
    {:ok, %{added: 1}} = Custom.add_ids(Scope.for_user(admin), [10])
    game = Repo.get_by!(Game, igdb_id: 10)

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/games/#{game.slug}")

    assert has_element?(view, "#game-log-footer #fix-match", "Fix match")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#fix-match") |> render_click()

    assert to =~ "/settings/matches?source_id="
  end

  test "non-admins never see the fix-match control", %{conn: conn} do
    admin = admin_user_fixture()
    {:ok, %{added: 1}} = Custom.add_ids(Scope.for_user(admin), [10])
    game = Repo.get_by!(Game, igdb_id: 10)

    viewer = viewer_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(viewer) |> live(~p"/games/#{game.slug}")

    refute has_element?(view, "#fix-match")
  end
end
