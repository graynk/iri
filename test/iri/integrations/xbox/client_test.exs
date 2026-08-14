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

defmodule Iri.Integrations.Xbox.ClientTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.Xbox.Client

  test "resolves gamertags and parses partial title history without exposing the key" do
    request = fn options, :xbox ->
      url = Keyword.fetch!(options, :url)
      assert String.starts_with?(url, "https://xbl.io/api/v2/")

      assert Enum.any?(Keyword.fetch!(options, :headers), fn {name, value} ->
               name == "x-authorization" and value == "fixture-key"
             end)

      body =
        if String.contains?(url, "/search/"),
          do: %{
            "people" => [
              %{"xuid" => "123", "gamertag" => "Player", "profilePicture" => "https://avatar"}
            ]
          },
          else: %{
            "titles" => [
              %{"titleId" => "42", "name" => "Halo", "lastTimePlayed" => "2026-01-01T00:00:00Z"}
            ]
          }

      {:ok, %Req.Response{status: 200, headers: %{}, body: %{"code" => 200, "content" => body}}}
    end

    options = [request: request, rate_limit: fn -> :ok end, observe: fn _, _ -> :ok end]

    assert {:ok, %{xuid: "123", gamertag: "Player"}} =
             Client.resolve_profile("Player", "fixture-key", options)

    assert {:ok, [entry]} =
             Client.fetch_library(%{external_user_id: "123"}, "fixture-key", options)

    assert entry.relationship == :played
    assert entry.external_id == "42"
  end

  test "resolves the exact suffixed gamertag instead of the first search result" do
    request = fn options, :xbox ->
      url = Keyword.fetch!(options, :url)
      assert String.contains?(url, "/search/Player")
      refute String.contains?(url, "%23")

      body = %{
        "people" => [
          %{
            "xuid" => "111",
            "gamertag" => "Player",
            "settings" => [
              %{"id" => "ModernGamertag", "value" => "Player"},
              %{"id" => "ModernGamertagSuffix", "value" => ""}
            ]
          },
          %{
            "xuid" => "222",
            "gamertag" => "Player",
            "settings" => [
              %{"id" => "ModernGamertag", "value" => "Player"},
              %{"id" => "ModernGamertagSuffix", "value" => "1234"},
              %{"id" => "UniqueModernGamertag", "value" => "Player#1234"}
            ]
          }
        ]
      }

      {:ok, %Req.Response{status: 200, headers: %{}, body: %{"code" => 200, "content" => body}}}
    end

    options = [request: request, rate_limit: fn -> :ok end, observe: fn _, _ -> :ok end]

    assert {:ok, %{xuid: "222", unique_gamertag: "Player#1234"}} =
             Client.resolve_profile("Player#1234", "fixture-key", options)

    assert {:ok, %{xuid: "111"}} = Client.resolve_profile("Player", "fixture-key", options)
  end

  test "drops demos, trials, and non-game titles from the imported history" do
    request = fn _options, :xbox ->
      body = %{
        "titles" => [
          %{"titleId" => "1", "name" => "Halo Infinite", "type" => "Game"},
          %{"titleId" => "2", "name" => "Vampire Survivors Demo", "type" => "Game"},
          %{"titleId" => "3", "name" => "The Riftbreaker (Demo)", "type" => "Game"},
          %{"titleId" => "4", "name" => "Sea of Thieves - Game Demo"},
          %{"titleId" => "5", "name" => "Forza Horizon 5 Trial", "type" => "Game"},
          %{"titleId" => "6", "name" => "Netflix", "type" => "App"},
          %{"titleId" => "7", "name" => "Trials Fusion", "type" => "Game"},
          %{"titleId" => "8", "name" => "Demon's Tilt"},
          %{
            "titleId" => "9",
            "name" => "Cyberpunk 2077",
            "type" => "Game",
            "devices" => ["Win32"]
          },
          %{
            "titleId" => "10",
            "name" => "Avowed",
            "type" => "Game",
            "devices" => ["PC", "XboxSeries"]
          },
          %{
            "titleId" => "11",
            "name" => "Forza Horizon 4: демоверсия",
            "type" => "Game",
            "devices" => ["PC", "XboxSeries"]
          },
          %{
            "titleId" => "12",
            "name" => "Minecraft Legends – Testversion",
            "type" => "Game",
            "devices" => ["XboxSeries"]
          }
        ]
      }

      {:ok, %Req.Response{status: 200, headers: %{}, body: %{"code" => 200, "content" => body}}}
    end

    options = [request: request, rate_limit: fn -> :ok end, observe: fn _, _ -> :ok end]

    assert {:ok, entries} =
             Client.fetch_library(%{external_user_id: "123"}, "fixture-key", options)

    assert Enum.map(entries, & &1.title) == [
             "Halo Infinite",
             "Trials Fusion",
             "Demon's Tilt",
             "Avowed"
           ]
  end
end
