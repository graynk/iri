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

defmodule Iri.LocalTimeTest do
  use ExUnit.Case, async: false

  alias Iri.LocalTime

  setup do
    original_time_zone = Application.get_env(:iri, :time_zone)

    on_exit(fn ->
      if original_time_zone do
        Application.put_env(:iri, :time_zone, original_time_zone)
      else
        Application.delete_env(:iri, :time_zone)
      end
    end)

    Application.put_env(:iri, :time_zone, "Europe/Berlin")
  end

  test "uses the configured timezone and its daylight-saving rules" do
    assert LocalTime.shift(~U[2026-01-15 12:00:00Z]).hour == 13
    assert LocalTime.shift(~U[2026-07-15 12:00:00Z]).hour == 14

    assert LocalTime.format(~U[2026-01-15 12:00:00Z], "%H:%M %Z") == "13:00 CET"
    assert LocalTime.format(~U[2026-07-15 12:00:00Z], "%H:%M %Z") == "14:00 CEST"
  end

  test "converts configured-local schedule times back to UTC for persistence" do
    assert LocalTime.utc_at(~D[2026-01-15], 3) == ~U[2026-01-15 02:00:00Z]
    assert LocalTime.utc_at(~D[2026-07-15], 3) == ~U[2026-07-15 01:00:00Z]
  end

  test "rejects an invalid configured timezone" do
    Application.put_env(:iri, :time_zone, "Middle/Earth")

    assert_raise RuntimeError, ~r/TZ must be a valid IANA timezone/, fn ->
      LocalTime.validate!()
    end
  end
end
