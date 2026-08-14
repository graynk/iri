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

defmodule Iri.LocalTime do
  @moduledoc "Converts persisted UTC timestamps to and from the configured local timezone."

  @utc "Etc/UTC"

  @doc "Returns the IANA timezone configured through `TZ`."
  def time_zone, do: Application.get_env(:iri, :time_zone, @utc)

  @doc "Raises during application startup when `TZ` is not a recognized IANA timezone."
  def validate! do
    case DateTime.now(time_zone()) do
      {:ok, _datetime} ->
        :ok

      {:error, reason} ->
        raise "TZ must be a valid IANA timezone such as Europe/Berlin, got #{inspect(time_zone())}: #{inspect(reason)}"
    end
  end

  @doc "Converts an absolute timestamp to the configured timezone."
  def shift(%DateTime{} = datetime), do: DateTime.shift_zone!(datetime, time_zone())

  @doc "Formats an absolute timestamp in the configured timezone."
  def format(%DateTime{} = datetime, format), do: datetime |> shift() |> Calendar.strftime(format)

  @doc "Returns the configured local calendar date for an absolute timestamp."
  def date(%DateTime{} = datetime), do: datetime |> shift() |> DateTime.to_date()

  @doc "Builds a configured-local wall time and converts it to UTC for persistence."
  def utc_at(%Date{} = date, hour) when hour in 0..23 do
    local_time = Time.new!(hour, 0, 0)

    local_datetime =
      case DateTime.new(date, local_time, time_zone()) do
        {:ok, datetime} -> datetime
        {:ambiguous, first, _second} -> first
        {:gap, _before, after_gap} -> after_gap
      end

    DateTime.shift_zone!(local_datetime, @utc)
  end
end
