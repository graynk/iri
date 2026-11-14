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

defmodule Iri.Params do
  @moduledoc "Shared parsing helpers for external and UI parameters."

  @spec positive_integer(term()) :: pos_integer() | nil
  def positive_integer(value) when is_integer(value) and value > 0, do: value

  def positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  def positive_integer(_value), do: nil

  @doc """
  Parses decimal hours typed by a user into whole minutes.

  A blank value clears the entry, so it parses as zero minutes.
  """
  @spec hours_to_minutes(term()) :: {:ok, non_neg_integer()} | :error
  def hours_to_minutes(nil), do: {:ok, 0}

  def hours_to_minutes(value) when is_float(value), do: minutes(value)
  def hours_to_minutes(value) when is_integer(value), do: minutes(value)

  def hours_to_minutes(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, 0}

      trimmed ->
        case Float.parse(trimmed) do
          {hours, ""} -> minutes(hours)
          _other -> integer_hours(trimmed)
        end
    end
  end

  def hours_to_minutes(_value), do: :error

  defp integer_hours(value) do
    case Integer.parse(value) do
      {hours, ""} -> minutes(hours)
      _other -> :error
    end
  end

  defp minutes(hours) when hours >= 0 and hours <= 100_000, do: {:ok, round(hours * 60)}
  defp minutes(_hours), do: :error
end
