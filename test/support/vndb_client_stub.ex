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

defmodule Iri.Integrations.VNDB.ClientStub do
  def lookup_steam_games(app_ids, options) do
    lookup_games(:steam, app_ids, options)
  end

  def lookup_games(provider, external_ids, options) do
    if test_pid = options[:test_pid], do: send(test_pid, {:vndb_lookup, provider, external_ids})
    {:ok, Keyword.get(options, :matches, %{})}
  end

  def search_games(query, options) do
    if test_pid = options[:test_pid], do: send(test_pid, {:vndb_search, query})
    {:ok, Keyword.get(options, :search_results, [])}
  end

  def games(ids, options) do
    if test_pid = options[:test_pid], do: send(test_pid, {:vndb_games, ids})
    {:ok, Keyword.get(options, :games, [])}
  end
end
