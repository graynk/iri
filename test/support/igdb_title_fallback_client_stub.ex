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

defmodule Iri.Integrations.IGDB.TitleFallbackClientStub do
  alias Iri.Integrations.IGDB.ClientStub

  def authenticate(client_id, client_secret, options),
    do: ClientStub.authenticate(client_id, client_secret, options)

  def discover_external_source(credentials, name, options),
    do: ClientStub.discover_external_source(credentials, name, options)

  def external_games(_credentials, _source_id, _uids, _options), do: {:ok, []}

  def search_games(credentials, search, options),
    do: ClientStub.search_games(credentials, search, options)

  def games(credentials, ids, options), do: ClientStub.games(credentials, ids, options)
end
