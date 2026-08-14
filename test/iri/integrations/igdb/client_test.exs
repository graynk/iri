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

defmodule Iri.Integrations.IGDB.ClientTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.IGDB.Client

  test "authenticates, discovers current source IDs, and builds exact UID queries" do
    test_pid = self()

    request = fn options, :igdb ->
      send(test_pid, {:request, options})

      cond do
        options[:url] =~ "oauth2/token" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"access_token" => "token", "expires_in" => 3_600}
           }}

        options[:url] =~ "external_game_sources" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: [
               %{"id" => 42, "name" => "Steam"},
               %{"id" => 45, "name" => "GOG.com"},
               %{"id" => 26, "name" => "Epic Games Store"},
               %{"id" => 36, "name" => "Playstation Store US"}
             ]
           }}

        options[:url] =~ "external_games" ->
          {:ok, %Req.Response{status: 200, body: [%{"uid" => "10", "game" => 100}]}}

        options[:url] =~ "game_time_to_beats" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: [%{"game_id" => 100, "hastily" => 18_000, "normally" => 46_800}]
           }}

        options[:url] =~ "/games" ->
          {:ok, %Req.Response{status: 200, body: [%{"id" => 100, "name" => "Fixture"}]}}
      end
    end

    options = [request: request, rate_limit: fn -> :ok end]
    assert {:ok, credentials} = Client.authenticate("client", "secret", options)
    assert {:ok, 42} = Client.discover_external_source(credentials, "Steam", options)
    assert {:ok, 45} = Client.discover_external_source(credentials, "GOG", options)
    assert {:ok, 26} = Client.discover_external_source(credentials, "Epic Game Store", options)
    assert {:ok, 36} = Client.discover_external_source(credentials, "PlayStation Store", options)
    assert {:ok, [%{"game" => 100}]} = Client.external_games(credentials, 42, ["10"], options)

    assert {:ok,
            [
              %{
                "id" => 100,
                "time_to_beat" => %{"hastily" => 18_000, "normally" => 46_800}
              }
            ]} = Client.games(credentials, [100], options)

    assert {:ok, [%{"id" => 100}]} =
             Client.search_games(credentials, "Fixture (TM)®", options)

    assert_received {:request, token_request}
    assert token_request[:params][:grant_type] == "client_credentials"
    assert_received {:request, source_request}
    assert source_request[:headers] |> Map.new() |> Map.fetch!("authorization") == "Bearer token"
    assert_received {:request, gog_source_request}
    assert gog_source_request[:body] =~ "fields id,name"
    assert_received {:request, epic_source_request}
    assert epic_source_request[:body] =~ "fields id,name"
    assert_received {:request, psn_source_request}
    assert psn_source_request[:body] =~ "fields id,name"
    assert_received {:request, mapping_request}
    assert mapping_request[:body] =~ "external_game_source = 42"
    assert mapping_request[:body] =~ "uid = (\"10\")"
    refute mapping_request[:body] =~ "category ="
    assert_received {:request, game_request}
    assert game_request[:body] =~ "cover.image_id"
    refute game_request[:body] =~ "game_type.type"
    refute game_request[:body] =~ "fields *"
    assert_received {:request, time_to_beat_request}
    assert time_to_beat_request[:url] =~ "game_time_to_beats"
    assert time_to_beat_request[:body] =~ "fields game_id,hastily,normally"
    assert time_to_beat_request[:body] =~ "where game_id = (100)"
    assert_received {:request, search_request}
    assert search_request[:body] =~ ~s(search "Fixture")
    assert search_request[:body] =~ "summary"
    assert search_request[:body] =~ "involved_companies.company.name"
    assert search_request[:body] =~ "involved_companies.developer"
    assert search_request[:body] =~ "involved_companies.publisher"
    refute search_request[:body] =~ "version_parent"
  end
end
