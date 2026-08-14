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

defmodule Iri.Integrations.IGDB.PartialFailureClientStub do
  alias Iri.Integrations.Error
  alias Iri.Integrations.IGDB.ClientStub

  def external_games(_credentials, _source_id, uids, _options) do
    mappings =
      Enum.flat_map(uids, fn uid ->
        if to_string(uid) == "10" do
          [%{"uid" => "10", "game" => 10_010, "name" => "Exact game"}]
        else
          []
        end
      end)

    {:ok, mappings}
  end

  def games(credentials, ids, options), do: ClientStub.games(credentials, ids, options)

  def search_games(_credentials, _search, _options) do
    {:error,
     %Error{
       kind: :transport,
       message: "fixture connection closed",
       retryable: true,
       provider: :igdb
     }}
  end
end
