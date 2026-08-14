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

defmodule Iri.Integrations.GOG.ClientStub do
  @behaviour Iri.Integrations.Provider

  def validate_profile(_profile, options \\ []) do
    if test_pid = options[:test_pid], do: send(test_pid, :gog_profile_validated)

    {:ok,
     %{
       username: "fixture-gog",
       display_name: "Fixture GOG player",
       total: 2
     }}
  end

  @impl true
  def fetch_library(_account, _payload, _options) do
    {:ok,
     [
       game("10", "Shared Fixture", 120),
       game("30", "GOG-only Fixture", 0)
     ]}
  end

  defp game(id, title, playtime) do
    %{
      "id" => id,
      "title" => title,
      "url" => "/game/#{Iri.Library.Title.slug(title)}",
      "image" => "//images.gog.test/#{id}",
      "achievement_support" => true,
      "stats" => %{"playtime" => playtime, "user_id" => "48628349971017"}
    }
  end
end
