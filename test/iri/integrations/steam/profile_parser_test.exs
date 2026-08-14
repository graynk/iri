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

defmodule Iri.Integrations.Steam.ProfileParserTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.Steam.ProfileParser

  test "accepts SteamID64 and profile URLs" do
    assert {:ok, {:steamid, "76561198000000001"}} =
             ProfileParser.parse("76561198000000001")

    assert {:ok, {:steamid, "76561198000000001"}} =
             ProfileParser.parse("https://steamcommunity.com/profiles/76561198000000001/")
  end

  test "accepts vanity names and vanity URLs" do
    assert {:ok, {:vanity, "fixture-player"}} = ProfileParser.parse("fixture-player")

    assert {:ok, {:vanity, "fixture_player"}} =
             ProfileParser.parse("https://steamcommunity.com/id/fixture_player/")
  end

  test "rejects lookalike hosts and unsupported paths" do
    assert {:error, :invalid_profile_host} =
             ProfileParser.parse("https://steamcommunity.com.example.test/id/player")

    assert {:error, :invalid_profile_path} =
             ProfileParser.parse("https://steamcommunity.com/groups/player")
  end
end
