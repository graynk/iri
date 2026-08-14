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

defmodule IriWeb.SteamOpenIDControllerTest do
  use IriWeb.ConnCase

  import Iri.AccountsFixtures

  test "admin starts Steam OpenID with a state-bound callback", %{conn: conn} do
    admin = admin_user_fixture()
    conn = conn |> log_in_user(admin) |> get(~p"/auth/steam")

    location = get_resp_header(conn, "location") |> List.first()
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert redirected_to(conn, 302) =~ "https://steamcommunity.com/openid/login"
    assert query["openid.mode"] == "checkid_setup"
    assert query["openid.return_to"] =~ "/auth/steam/callback?state="
    assert %{state: state, purpose: :connect} = get_session(conn, :steam_openid)
    assert is_binary(state)
  end

  test "any visitor can start Steam login", %{conn: conn} do
    conn = get(conn, ~p"/users/log-in/steam")

    assert redirected_to(conn, 302) =~ "https://steamcommunity.com/openid/login"
    assert %{purpose: :login} = get_session(conn, :steam_openid)
  end

  test "viewer can attach their own Steam account", %{conn: conn} do
    viewer = viewer_user_fixture()
    conn = conn |> log_in_user(viewer) |> get(~p"/auth/steam")

    assert redirected_to(conn) =~ "steamcommunity.com/openid/login"
  end
end
