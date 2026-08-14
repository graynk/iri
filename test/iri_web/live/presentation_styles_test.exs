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

defmodule IriWeb.PresentationStylesTest do
  use ExUnit.Case, async: true

  alias IriWeb.GameLive.Presentation, as: GamePresentation
  alias IriWeb.LibraryLive.CardPresentation

  @neutral_card_classes "bg-slate-800 text-slate-300"
  @neutral_detail_classes "bg-slate-800 text-slate-300 ring-slate-700"

  test "library platform, controller, and VR badges use neutral theme colors" do
    badges = CardPresentation.compatibility_badges(compatibility_source())

    assert {"Win · Mac · Linux", @neutral_card_classes} in badges
    assert {"Controller", @neutral_card_classes} in badges
    assert {"VR only", @neutral_card_classes} in badges
    assert {"Deck verified", "bg-sky-400/10 text-sky-200"} in badges
    assert {"ProtonDB Gold", "bg-emerald-400/10 text-emerald-200"} in badges
  end

  test "game detail platform, controller, and VR badges use neutral theme colors" do
    source =
      compatibility_source()
      |> Map.put(:library_items, [
        %{removed_at: nil, provider_account: %{enabled: true}}
      ])

    details = GamePresentation.compatibility_details(%{sources: [source]})

    assert {"Windows · macOS · Linux", @neutral_detail_classes} in details
    assert {"Full controller support", @neutral_detail_classes} in details
    assert {"VR required", @neutral_detail_classes} in details

    assert {"Steam Deck verified", "bg-sky-400/10 text-sky-200 ring-sky-400/20"} in details
  end

  defp compatibility_source do
    %{
      available_windows: true,
      available_mac: true,
      available_linux: true,
      controller_support: "full",
      deck_compatibility: "verified",
      protondb_tier: "gold",
      vr_support: "required"
    }
  end
end
