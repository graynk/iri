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

defmodule Iri.Integrations.Xbox.RateLimiterTest do
  use Iri.DataCase

  alias Iri.Integrations.ProviderRateLimit
  alias Iri.Integrations.Xbox.RateLimiter

  test "coordinates a conservative hourly budget in SQLite" do
    now = ~U[2026-07-17 10:00:00Z]

    %ProviderRateLimit{}
    |> ProviderRateLimit.changeset(%{
      provider: "openxbl",
      requests_observed: 139,
      window_ends_at: DateTime.add(now, 3600, :second)
    })
    |> Repo.insert!()

    assert :ok = RateLimiter.acquire(now)
    assert {:error, {:rate_limited, ~U[2026-07-17 11:00:00Z]}} = RateLimiter.acquire(now)
  end

  test "a 429 persists its retry window" do
    now = ~U[2026-07-17 10:00:00Z]
    assert :ok = RateLimiter.acquire(now)
    assert :ok = RateLimiter.observe(%{"retry-after" => ["120"]}, 429, now)
    assert {:error, {:rate_limited, ~U[2026-07-17 10:02:00Z]}} = RateLimiter.acquire(now)
  end
end
