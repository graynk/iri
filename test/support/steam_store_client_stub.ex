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

defmodule Iri.Integrations.Steam.StoreClientStub do
  def fetch_store_metadata(app_id, options) do
    if test_pid = options[:test_pid], do: send(test_pid, {:compatibility_fetched, app_id})

    {:ok,
     %{
       catalog_kind: "game",
       nsfw: Keyword.get(options, :nsfw, false),
       controller_support: "full",
       available_windows: true,
       available_mac: false,
       available_linux: true,
       vr_support: "supported"
     }}
  end

  def fetch_deck_compatibility(app_id, options) do
    if test_pid = options[:test_pid], do: send(test_pid, {:deck_compatibility_fetched, app_id})
    {:ok, "verified"}
  end
end
