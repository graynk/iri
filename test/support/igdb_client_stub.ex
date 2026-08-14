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

defmodule Iri.Integrations.IGDB.ClientStub do
  def authenticate(client_id, _client_secret, options) do
    if test_pid = options[:test_pid], do: send(test_pid, :igdb_authenticated)

    {:ok,
     %{
       "client_id" => client_id,
       "access_token" => "fixture-access-token",
       "expires_at" => DateTime.add(DateTime.utc_now(:second), 3_600, :second)
     }}
  end

  def discover_external_source(_credentials, "Steam", _options), do: {:ok, 1}
  def discover_external_source(_credentials, "GOG", _options), do: {:ok, 5}

  def external_games(_credentials, _source_id, uids, _options) do
    {:ok,
     Enum.flat_map(uids, fn uid ->
       case Integer.parse(to_string(uid)) do
         {appid, ""} ->
           [%{"uid" => to_string(uid), "game" => 10_000 + appid, "name" => "IGDB #{uid}"}]

         _error ->
           []
       end
     end)}
  end

  def games(_credentials, ids, _options) do
    {:ok, Enum.map(ids, &game_payload/1)}
  end

  def search_games(_credentials, search, _options) do
    {:ok,
     [
       %{
         "id" => 90_001,
         "name" => search,
         "summary" => "A searchable fixture game used to identify this result.",
         "first_release_date" => 1_600_000_000,
         "game_type" => %{"type" => "Main Game"},
         "platforms" => [%{"id" => 6, "name" => "PC (Microsoft Windows)"}],
         "involved_companies" => [
           %{
             "company" => %{"name" => "Fixture Studio"},
             "developer" => true
           }
         ]
       }
     ]}
  end

  defp game_payload(id) do
    %{
      "id" => id,
      "name" => "Canonical Game #{id}",
      "slug" => "canonical-game-#{id}",
      "summary" => "A locally stored fixture description.",
      "first_release_date" => 1_600_000_000,
      "updated_at" => 1_700_000_000,
      "total_rating" => 88.5,
      "time_to_beat" => %{"game_id" => id, "hastily" => 18_000, "normally" => 46_800},
      "game_type" => %{"type" => "Main Game"},
      "genres" => [%{"id" => 12, "name" => "Role-playing (RPG)", "slug" => "role-playing-rpg"}],
      "themes" => [%{"id" => 18, "name" => "Science fiction", "slug" => "science-fiction"}],
      "game_modes" => [%{"id" => 1, "name" => "Single player", "slug" => "single-player"}],
      "platforms" => [%{"id" => 6, "name" => "PC (Microsoft Windows)", "slug" => "win"}],
      "cover" => %{"image_id" => "co-shared", "width" => 600, "height" => 800},
      "screenshots" => [],
      "videos" => [],
      "involved_companies" => [
        %{
          "company" => %{"id" => 47, "name" => "Fixture Studio", "slug" => "fixture-studio"},
          "developer" => true,
          "publisher" => false
        },
        %{
          "company" => %{"id" => 47, "name" => "Fixture Studio", "slug" => "fixture-studio"},
          "developer" => true,
          "publisher" => false
        }
      ]
    }
  end
end
