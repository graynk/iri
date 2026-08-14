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

defmodule Iri.AI.Worker do
  @moduledoc "Processes durable AI match reviews one at a time."

  use GenServer

  alias Iri.AI
  alias Iri.AI.Config

  @default_tick_ms 5_000

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(options) do
    state = %{tick_ms: Keyword.get(options, :tick_ms, @default_tick_ms), timer: nil}
    {:ok, state}
  end

  @impl true
  def handle_cast(:wake, state) do
    {:noreply, schedule(state, 0)}
  end

  @impl true
  def handle_info(:tick, state) do
    state = %{state | timer: nil}

    delay =
      case Config.current() |> Config.enabled() do
        {:ok, config} -> if(process_one(config) == :processed, do: 0, else: state.tick_ms)
        {:disabled, _reason} -> state.tick_ms
      end

    {:noreply, schedule(state, delay)}
  end

  defp process_one(config) do
    case AI.claim_next(config) do
      {:ok, review} ->
        _result = AI.execute(review, config)
        :processed

      :none ->
        :idle
    end
  end

  defp schedule(%{timer: timer} = state, delay) do
    if timer, do: Process.cancel_timer(timer)
    %{state | timer: Process.send_after(self(), :tick, delay)}
  end
end
