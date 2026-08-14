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

defmodule Iri.Library.StoreLinkTest do
  use ExUnit.Case, async: true

  alias Iri.Library.StoreLink

  test "builds a Steam store link from the app id" do
    assert StoreLink.build(:steam, "620", nil) ==
             %{store: "Steam", url: "https://store.steampowered.com/app/620"}
  end

  test "uses the stored web url for GOG and other providers" do
    assert StoreLink.build(:gog, "1", "https://www.gog.com/game/portal") ==
             %{store: "GOG", url: "https://www.gog.com/game/portal"}

    assert StoreLink.build(:epic, "x", "https://store.epicgames.com/p/x") ==
             %{store: "EPIC", url: "https://store.epicgames.com/p/x"}
  end

  test "ignores non-web urls" do
    assert StoreLink.build(:gog, "1", nil) == nil
    assert StoreLink.build(:gog, "1", "steam://run/1") == nil
  end

  test "for_sources dedupes by url" do
    sources = [
      %{provider: :steam, external_id: "620", source_url: nil},
      %{provider: :steam, external_id: "620", source_url: nil},
      %{provider: :gog, external_id: "1", source_url: "https://www.gog.com/game/portal"}
    ]

    assert StoreLink.for_sources(sources) == [
             %{store: "Steam", url: "https://store.steampowered.com/app/620"},
             %{store: "GOG", url: "https://www.gog.com/game/portal"}
           ]
  end
end
