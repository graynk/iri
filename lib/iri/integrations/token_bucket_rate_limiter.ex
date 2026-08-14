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

defmodule Iri.Integrations.TokenBucketRateLimiter do
  @moduledoc """
  Reserves evenly spaced request slots for in-memory provider rate limits.

  Each instance has independent state and must be started with an explicit
  supervision `:id` or registered `:name`.
  """

  use GenServer

  def child_spec(options) do
    id =
      Keyword.get_lazy(options, :id, fn ->
        {__MODULE__, Keyword.fetch!(options, :name)}
      end)

    %{
      id: id,
      start: {__MODULE__, :start_link, [options]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(options) do
    gen_server_options =
      case Keyword.get(options, :name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, options, gen_server_options)
  end

  def acquire(server), do: GenServer.call(server, :acquire, :infinity)

  @impl true
  def init(options) do
    interval_ms = Keyword.fetch!(options, :interval_ms)

    if is_integer(interval_ms) and interval_ms > 0 do
      clock = Keyword.get(options, :clock, fn -> System.monotonic_time(:millisecond) end)
      schedule = Keyword.get(options, :schedule, &Process.send_after/3)

      {:ok,
       %{
         interval_ms: interval_ms,
         next_slot: clock.(),
         clock: clock,
         schedule: schedule
       }}
    else
      {:stop, :invalid_interval}
    end
  end

  @impl true
  def handle_call(:acquire, from, state) do
    now = state.clock.()
    reserved = max(now, state.next_slot)
    delay = reserved - now
    state = %{state | next_slot: reserved + state.interval_ms}

    if delay == 0 do
      {:reply, :ok, state}
    else
      state.schedule.(self(), {:release, from}, delay)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:release, from}, state) do
    GenServer.reply(from, :ok)
    {:noreply, state}
  end
end
