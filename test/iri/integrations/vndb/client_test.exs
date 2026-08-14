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

defmodule Iri.Integrations.VNDB.ClientTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.VNDB.Client

  test "looks up releases by exact Steam AppID" do
    request = fn options, :vndb ->
      send(self(), {:request, options})

      case URI.parse(options[:url]).path do
        "/kana/release" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "results" => [
                 %{
                   "id" => "r12",
                   "has_ero" => true,
                   "minage" => 18,
                   "extlinks" => [%{"name" => "steam", "id" => 702_050}],
                   "vns" => [%{"id" => "v17"}]
                 }
               ]
             }
           }}

        "/kana/vn" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"results" => [%{"id" => "v17", "title" => "Fixture Novel"}]}
           }}
      end
    end

    assert {:ok, %{"702050" => [game]}} =
             Client.lookup_steam_games(["702050"], request: request)

    assert game["id"] == "v17"
    assert game["_release"]["has_ero"]

    assert_received {:request, release_options}
    assert release_options[:url] == "https://api.vndb.org/kana/release"
    assert release_options[:json].filters == ["extlink", "=", ["steam", 702_050]]
    assert release_options[:json].fields == "id,minage,has_ero,extlinks{name,id},vns{id}"
    refute release_options[:json].fields =~ "screenshots"

    assert_received {:request, game_options}
    assert game_options[:url] == "https://api.vndb.org/kana/vn"
    assert game_options[:json].filters == ["id", "=", "v17"]
  end

  test "looks up releases by exact GOG product slug" do
    request = fn options, :vndb ->
      send(self(), {:request, options})

      case URI.parse(options[:url]).path do
        "/kana/release" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "results" => [
                 %{
                   "id" => "r44",
                   "extlinks" => [%{"name" => "gog", "id" => "fixture_novel"}],
                   "vns" => [%{"id" => "v44"}]
                 }
               ]
             }
           }}

        "/kana/vn" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"results" => [%{"id" => "v44", "title" => "Fixture Novel"}]}
           }}
      end
    end

    assert {:ok, %{"fixture_novel" => [%{"id" => "v44"}]}} =
             Client.lookup_games(:gog, ["fixture_novel"], request: request)

    assert_received {:request, release_options}
    assert release_options[:json].filters == ["extlink", "=", ["gog", "fixture_novel"]]
    assert_received {:request, game_options}
    assert game_options[:json].filters == ["id", "=", "v44"]
  end

  test "does not fetch VN details when no release links match" do
    request = fn options, :vndb ->
      send(self(), {:request, options})
      {:ok, %Req.Response{status: 200, body: %{"results" => []}}}
    end

    assert {:ok, %{}} = Client.lookup_steam_games(["10", "20"], request: request)

    assert_received {:request, release_options}
    assert release_options[:url] == "https://api.vndb.org/kana/release"
    refute_received {:request, _options}
  end

  test "chunks VN detail requests at the API identifier limit" do
    request = fn options, :vndb ->
      send(self(), {:request, options})
      {:ok, %Req.Response{status: 200, body: %{"results" => []}}}
    end

    ids = Enum.map(1..101, &"v#{&1}")

    assert {:ok, []} = Client.games(ids, request: request)

    assert_received {:request, first_options}
    assert first_options[:json].results == 100
    assert ["or" | first_filters] = first_options[:json].filters
    assert length(first_filters) == 100

    assert_received {:request, second_options}
    assert second_options[:json].results == 1
    assert second_options[:json].filters == ["id", "=", "v101"]
  end

  test "searches visual novels by title and fetches an exact VNDB ID" do
    request = fn options, :vndb ->
      send(self(), {:request, options})
      {:ok, %Req.Response{status: 200, body: %{"results" => [%{"id" => "v17"}]}}}
    end

    assert {:ok, [%{"id" => "v17"}]} =
             Client.search_games("  Fixture (TM) Novel®  ", request: request)

    assert_received {:request, search_options}
    assert search_options[:url] == "https://api.vndb.org/kana/vn"
    assert search_options[:json].filters == ["search", "=", "Fixture Novel"]
    assert search_options[:json].sort == "searchrank"

    assert {:ok, [%{"id" => "v17"}]} = Client.games(["v17"], request: request)
    assert_received {:request, game_options}
    assert game_options[:json].filters == ["id", "=", "v17"]
  end
end
