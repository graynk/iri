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

defmodule Iri.Integrations.ProtonDB.ClientStub do
  def fetch_tier(app_id, etag, options) do
    if test_pid = options[:test_pid], do: send(test_pid, {:protondb_fetched, app_id, etag})

    {:ok,
     %{
       tier: Keyword.get(options, :tier, "gold"),
       etag: Keyword.get(options, :etag, ~s("fixture-protondb-etag"))
     }}
  end
end
