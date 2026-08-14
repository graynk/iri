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

defmodule Iri.Integrations.Steam.StoreRateLimitedClientStub do
  alias Iri.Integrations.Error

  def fetch_store_metadata(app_id, options) do
    attempt = Agent.get_and_update(options[:counter], &{&1 + 1, &1 + 1})
    if test_pid = options[:test_pid], do: send(test_pid, {:store_attempt, app_id, attempt})

    if attempt in [1, 2] do
      {:error,
       %Error{
         kind: :rate_limited,
         message: "STEAM returned HTTP 429.",
         retryable: true,
         status: 429,
         provider: :steam,
         retry_after_seconds: if(attempt == 1, do: 2)
       }}
    else
      {:ok,
       %{
         catalog_kind: "game",
         nsfw: false,
         controller_support: "full",
         available_windows: true,
         available_mac: false,
         available_linux: true,
         vr_support: "none"
       }}
    end
  end

  def fetch_deck_compatibility(_app_id, _options), do: {:ok, "verified"}
end
