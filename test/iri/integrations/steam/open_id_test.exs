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

defmodule Iri.Integrations.Steam.OpenIDTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.Error
  alias Iri.Integrations.Steam.OpenID

  test "builds an OpenID 2.0 account-picker URL" do
    url =
      OpenID.authentication_url(
        "https://iri.test/auth/steam/callback",
        "https://iri.test/"
      )

    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["openid.mode"] == "checkid_setup"
    assert query["openid.return_to"] == "https://iri.test/auth/steam/callback"

    assert query["openid.identity"] ==
             "http://specs.openid.net/auth/2.0/identifier_select"
  end

  test "verifies the assertion with Steam and extracts SteamID64" do
    return_to = "https://iri.test/auth/steam/callback?state=state"

    params = %{
      "openid.return_to" => return_to,
      "openid.claimed_id" => "https://steamcommunity.com/openid/id/76561198000000001",
      "openid.mode" => "id_res"
    }

    request = fn options, :steam ->
      assert options[:form]["openid.mode"] == "check_authentication"

      {:ok,
       %Req.Response{status: 200, body: "ns:http://specs.openid.net/auth/2.0\nis_valid:true\n"}}
    end

    assert {:ok, "76561198000000001"} =
             OpenID.verify(params, return_to, request: request)
  end

  test "rejects a mismatched return URL before making a request" do
    params = %{
      "openid.return_to" => "https://attacker.test/",
      "openid.claimed_id" => "https://steamcommunity.com/openid/id/76561198000000001"
    }

    assert {:error, %Error{kind: :authentication}} =
             OpenID.verify(params, "https://iri.test/auth/steam/callback")
  end
end
