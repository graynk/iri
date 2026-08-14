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

defmodule Iri.Integrations.Steam.ClientStub do
  @behaviour Iri.Integrations.Provider

  @impl true
  def fetch_library(_account, _payload, _options) do
    {:ok,
     [
       %{
         "appid" => 10,
         "name" => "Counter-Strike",
         "playtime_forever" => 180,
         "rtime_last_played" => 1_700_000_000
       },
       %{"appid" => 20, "name" => "Team Fortress Classic", "playtime_forever" => 0}
     ]}
  end

  def validate_setup(profile, _api_key, _options) do
    steamid = if Regex.match?(~r/^\d{17}$/, profile), do: profile, else: "76561198000000001"

    {:ok,
     %{
       steamid: steamid,
       display_name: "Fixture player",
       game_count: 2
     }}
  end
end
