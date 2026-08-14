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

defmodule Iri.Integrations.Epic.LegendaryParserTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.Epic.LegendaryParser

  test "imports base games and ignores DLC records" do
    export =
      Jason.encode!([
        %{
          "app_name" => "Base",
          "title" => "Base Game",
          "metadata" => %{
            "id" => "catalog-base",
            "title" => "Base Game",
            "namespace" => "ns",
            "categories" => [%{"path" => "games"}],
            "keyImages" => [%{"type" => "OfferImageTall", "url" => "https://images/base.jpg"}]
          }
        },
        %{
          "app_name" => "DLC",
          "title" => "Soundtrack",
          "is_dlc" => true,
          "metadata" => %{
            "id" => "catalog-dlc",
            "title" => "Soundtrack",
            "categories" => [%{"path" => "addons"}]
          }
        }
      ])

    assert {:ok, [entry]} = LegendaryParser.parse(export)
    assert entry.external_id == "catalog-base"
    assert entry.title == "Base Game"
    assert get_in(entry, [:metadata, "legendary", "image"]) == "https://images/base.jpg"
  end

  test "rejects malformed exports" do
    assert {:error, :invalid_json} = LegendaryParser.parse("not-json")
    assert {:error, :invalid_legendary_export} = LegendaryParser.parse(~s({"games": []}))
  end
end
