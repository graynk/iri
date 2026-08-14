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

defmodule Iri.Integrations.Steam.ClientTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.Error
  alias Iri.Integrations.Steam.Client

  @api_key "0123456789abcdef0123456789abcdef"

  test "validates a numeric profile and its visible owned games" do
    request = fixture_request(self())

    assert {:ok, setup} =
             Client.validate_setup("76561198000000001", @api_key, request: request)

    assert setup.steamid == "76561198000000001"
    assert setup.display_name == "Fixture player"
    assert setup.game_count == 2

    assert_received {:request, profile_options}
    assert profile_options[:url] =~ "GetPlayerSummaries"
    assert_received {:request, owned_options}
    assert owned_options[:url] =~ "GetOwnedGames"
    assert owned_options[:params][:include_played_free_games]
    refute owned_options[:params][:skip_unvetted_apps]
    refute_receive {:request, _options}
  end

  test "resolves a vanity profile before validation" do
    request = fixture_request(self())

    assert {:ok, setup} = Client.validate_setup("fixture-player", @api_key, request: request)
    assert setup.steamid == "76561198000000001"

    assert_received {:request, vanity_options}
    assert vanity_options[:url] =~ "ResolveVanityURL"
  end

  test "diagnoses an empty or private library without accepting it" do
    request = fn options, :steam ->
      cond do
        options[:url] =~ "GetPlayerSummaries" ->
          {:ok, response(%{"response" => %{"players" => [profile()]}})}

        options[:url] =~ "GetOwnedGames" ->
          {:ok, response(%{"response" => %{}})}
      end
    end

    assert {:error, %Error{kind: :library_not_visible, retryable: false}} =
             Client.validate_setup("76561198000000001", @api_key, request: request)
  end

  defp fixture_request(test_pid) do
    fn options, :steam ->
      send(test_pid, {:request, Map.new(options)})

      cond do
        options[:url] =~ "ResolveVanityURL" ->
          {:ok,
           response(%{
             "response" => %{"success" => 1, "steamid" => "76561198000000001"}
           })}

        options[:url] =~ "GetPlayerSummaries" ->
          {:ok, response(%{"response" => %{"players" => [profile()]}})}

        options[:url] =~ "GetOwnedGames" ->
          {:ok,
           response(%{
             "response" => %{
               "game_count" => 2,
               "games" => [
                 %{"appid" => 10, "name" => "Counter-Strike"},
                 %{"appid" => 20, "name" => "Team Fortress Classic"}
               ]
             }
           })}
      end
    end
  end

  defp profile do
    %{
      "steamid" => "76561198000000001",
      "personaname" => "Fixture player",
      "profileurl" => "https://steamcommunity.com/profiles/76561198000000001/",
      "avatarfull" => "https://avatars.steamstatic.com/fixture_full.jpg"
    }
  end

  defp response(body), do: %Req.Response{status: 200, body: body}
end
