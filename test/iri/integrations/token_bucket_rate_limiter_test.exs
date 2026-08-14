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

defmodule Iri.Integrations.TokenBucketRateLimiterTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.GOG
  alias Iri.Integrations.IGDB
  alias Iri.Integrations.TokenBucketRateLimiter

  test "reserves request slots in order without blocking the server" do
    limiter = start_limiter(100)
    task_supervisor = start_supervised!(Task.Supervisor)

    assert :ok = TokenBucketRateLimiter.acquire(limiter)

    second =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        TokenBucketRateLimiter.acquire(limiter)
      end)

    assert_receive {:reservation_scheduled, ^limiter, second_release, 100}

    third =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        TokenBucketRateLimiter.acquire(limiter)
      end)

    assert_receive {:reservation_scheduled, ^limiter, third_release, 200}
    assert Task.yield(second, 0) == nil
    assert Task.yield(third, 0) == nil

    send(limiter, second_release)
    assert Task.await(second, 1_000) == :ok
    assert Task.yield(third, 0) == nil

    send(limiter, third_release)
    assert Task.await(third, 1_000) == :ok
  end

  test "instances keep independent schedules and child identities" do
    gog = start_limiter(500)
    igdb = start_limiter(334)
    task_supervisor = start_supervised!(Task.Supervisor)

    assert :ok = TokenBucketRateLimiter.acquire(gog)
    assert :ok = TokenBucketRateLimiter.acquire(igdb)

    gog_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        TokenBucketRateLimiter.acquire(gog)
      end)

    igdb_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        TokenBucketRateLimiter.acquire(igdb)
      end)

    assert_receive {:reservation_scheduled, ^gog, gog_release, 500}
    assert_receive {:reservation_scheduled, ^igdb, igdb_release, 334}

    send(gog, gog_release)
    send(igdb, igdb_release)
    assert Task.await(gog_task, 1_000) == :ok
    assert Task.await(igdb_task, 1_000) == :ok

    assert GOG.RateLimiter.child_spec([]).id == GOG.RateLimiter
    assert IGDB.RateLimiter.child_spec([]).id == IGDB.RateLimiter
  end

  defp start_limiter(interval_ms) do
    test_pid = self()

    schedule = fn destination, message, delay ->
      send(test_pid, {:reservation_scheduled, destination, message, delay})
      make_ref()
    end

    start_supervised!(
      {TokenBucketRateLimiter,
       id: make_ref(), interval_ms: interval_ms, clock: fn -> 1_000 end, schedule: schedule}
    )
  end
end
