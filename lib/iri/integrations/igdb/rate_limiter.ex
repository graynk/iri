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

defmodule Iri.Integrations.IGDB.RateLimiter do
  @moduledoc "Reserves IGDB request slots at a conservative three requests per second."

  alias Iri.Integrations.TokenBucketRateLimiter

  @interval_ms 334

  def start_link(options) do
    options
    |> Keyword.merge(name: __MODULE__, interval_ms: @interval_ms)
    |> TokenBucketRateLimiter.start_link()
  end

  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def acquire, do: TokenBucketRateLimiter.acquire(__MODULE__)
end
