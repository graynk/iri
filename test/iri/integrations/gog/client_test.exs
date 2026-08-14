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

defmodule Iri.Integrations.GOG.ClientTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.GOG.Client

  test "normalizes public profile names and URLs" do
    assert {:ok, "graynk"} = Client.normalize_username("graynk")
    assert {:ok, "graynk"} = Client.normalize_username("https://www.gog.com/u/graynk/games")

    assert {:error, :invalid_gog_profile} =
             Client.normalize_username("https://example.com/u/graynk")
  end

  test "fetches every public stats page and keeps playtime" do
    request = fn options, :gog ->
      page = Keyword.fetch!(options, :params)[:page]
      body = page(page)
      {:ok, %Req.Response{status: 200, headers: %{}, body: body}}
    end

    account = %{external_user_id: "graynk"}

    assert {:ok, games} =
             Client.fetch_library(account, %{}, request: request, rate_limit: fn -> :ok end)

    assert Enum.map(games, & &1["id"]) == ["10", "20"]
    assert get_in(hd(games), ["stats", "playtime"]) == 123
  end

  test "does not request a phantom second page for a one-page profile" do
    request = fn options, :gog ->
      assert Keyword.fetch!(options, :params)[:page] == 1

      {:ok,
       %Req.Response{status: 200, headers: %{}, body: %{page(1) | "pages" => 1, "total" => 1}}}
    end

    assert {:ok, [_]} =
             Client.fetch_library(%{external_user_id: "graynk"}, %{},
               request: request,
               rate_limit: fn -> :ok end
             )
  end

  test "filters downloadable extras returned as game-shaped public products" do
    request = fn _options, :gog ->
      items = [
        item(1, "Cyberpunk 2077"),
        item(2, "Cyberpunk 2077 Goodies Collection"),
        item(3, "The Witcher 3 REDkit"),
        item(4, "GOG Product 1601676413"),
        item(5, "Game Name - Soundtrack")
      ]

      {:ok,
       %Req.Response{
         status: 200,
         headers: %{},
         body: %{
           "page" => 1,
           "pages" => 1,
           "total" => length(items),
           "_embedded" => %{"items" => items}
         }
       }}
    end

    assert {:ok, [%{"title" => "Cyberpunk 2077"}]} =
             Client.fetch_library(%{external_user_id: "graynk"}, %{},
               request: request,
               rate_limit: fn -> :ok end
             )
  end

  defp page(number) do
    id = number * 10

    %{
      "page" => number,
      "pages" => 2,
      "total" => 2,
      "_embedded" => %{
        "items" => [
          %{
            "game" => %{
              "id" => id,
              "title" => "Game #{id}",
              "url" => "/game/game_#{id}",
              "image" => "//images/#{id}",
              "achievementSupport" => true
            },
            "stats" => %{"1234" => %{"playtime" => 123, "lastSession" => "2026-01-01T00:00:00Z"}}
          }
        ]
      }
    }
  end

  defp item(id, title) do
    %{
      "game" => %{
        "id" => id,
        "title" => title,
        "url" => "/game/#{id}",
        "image" => "//images/#{id}",
        "achievementSupport" => false
      },
      "stats" => %{}
    }
  end
end
