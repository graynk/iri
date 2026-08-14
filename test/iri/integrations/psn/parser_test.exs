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

defmodule Iri.Integrations.PSN.ParserTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.PSN.Parser

  test "keeps partial history additive and validates complete purchased pagination" do
    base = %{
      "schema" => "iri-psn-export/v1",
      "account" => %{"id" => "123", "online_id" => "Player"}
    }

    item = %{
      "conceptId" => "1000",
      "name" => "Astro",
      "lastPlayedDateTime" => "2026-01-01T00:00:00Z"
    }

    partial =
      Map.put(base, "datasets", [%{"kind" => "played", "complete" => true, "items" => [item]}])

    assert {:ok, %{complete?: false, entries: [entry]}} = Parser.parse(Jason.encode!(partial))
    assert entry.relationship == :played

    complete =
      Map.put(base, "datasets", [
        %{
          "kind" => "purchased",
          "complete" => true,
          "pagination" => %{"pages_observed" => 2, "final" => true},
          "items" => [item]
        }
      ])

    assert {:ok, %{complete?: true, entries: [entry]}} = Parser.parse(Jason.encode!(complete))
    assert entry.relationship == :owned
  end

  test "accepts collector v2 with a visible online ID and keeps purchased over played" do
    purchased = %{"conceptId" => "1000", "name" => "Astro"}

    played = %{
      "conceptId" => "1000",
      "name" => "Astro",
      "lastPlayedDateTime" => "2026-01-01T00:00:00Z"
    }

    export = %{
      "schema" => "iri-psn-export/v2",
      "datasets" => [
        %{"kind" => "played", "items" => [played]},
        %{"kind" => "purchased", "items" => [purchased]}
      ]
    }

    assert {:ok, %{account: account, complete?: false, entries: [entry]}} =
             Parser.parse(Jason.encode!(export), "Player Name")

    assert account == %{id: "player name", name: "Player Name"}
    assert entry.relationship == :owned
    assert {:error, :missing_account} = Parser.parse(Jason.encode!(export))
  end

  test "accepts collector v3 exports including DOM-derived title identifiers" do
    export = %{
      "schema" => "iri-psn-export/v3",
      "account" => %{"id" => "123456789", "online_id" => "Spieler"},
      "datasets" => [
        %{
          "kind" => "purchased",
          "complete" => false,
          "pagination" => %{"pages_observed" => 1, "final" => false},
          "items" => [
            %{"concept_id" => "10002000", "title_id" => nil, "name" => "Astro Bot"},
            %{"concept_id" => nil, "title_id" => "dom-9f3a2b1c", "name" => "Gran Turismo 7"}
          ]
        },
        %{
          "kind" => "played",
          "complete" => false,
          "pagination" => %{"pages_observed" => 1, "final" => false},
          "items" => [
            %{
              "concept_id" => "10002000",
              "title_id" => "CUSA00001_00",
              "name" => "Astro Bot",
              "last_played_at" => "2026-02-01T00:00:00Z"
            }
          ]
        }
      ]
    }

    assert {:ok, %{account: account, complete?: false, entries: entries}} =
             Parser.parse(Jason.encode!(export))

    assert account == %{id: "123456789", name: "Spieler"}
    assert length(entries) == 2

    astro = Enum.find(entries, &(&1.external_id == "10002000"))
    assert astro.relationship == :owned

    assert Enum.any?(entries, &(&1.external_id == "dom-9f3a2b1c"))
  end

  test "drops media products and folds DOM duplicates into real identifiers" do
    export = %{
      "schema" => "iri-psn-export/v3",
      "datasets" => [
        %{
          "kind" => "played",
          "items" => [
            %{"concept_id" => "10001111", "name" => "Pragmata"},
            %{"concept_id" => "10002222", "name" => "Pragmata Sketchbook"},
            %{"concept_id" => "10003333", "name" => "Stellar Blade Demo"},
            %{"concept_id" => "10004444", "name" => "NieR:Automata Original Soundtrack"},
            %{"concept_id" => "10005555", "name" => "Final Fantasy VII Testversion"},
            %{"concept_id" => "10006666", "name" => "Spielwelten Skizzenbuch"},
            %{"concept_id" => nil, "title_id" => "dom-11aa22bb", "name" => "PRAGMATA"}
          ]
        },
        %{
          "kind" => "purchased",
          "items" => [
            %{"concept_id" => nil, "title_id" => "dom-33cc44dd", "name" => "Ghost of Tsushima"}
          ]
        }
      ]
    }

    assert {:ok, %{entries: entries}} = Parser.parse(Jason.encode!(export), "Spieler")

    assert Enum.map(entries, & &1.external_id) |> Enum.sort() == ["10001111", "dom-33cc44dd"]
    refute Enum.any?(entries, &(&1.title =~ "Sketchbook"))

    assert Parser.non_game_source?(%{source_title: "Pragmata Sketchbook"})
    refute Parser.non_game_source?(%{source_title: "Pragmata"})
  end

  test "accepts German purchased records which expose only a product ID" do
    export = %{
      "schema" => "iri-psn-export/v3",
      "datasets" => [
        %{
          "kind" => "purchased",
          "items" => [
            %{
              "product_id" => "EP9000-PPSA08338_00-GOWRAGNAROK00000",
              "name" => "God of War Ragnarök"
            }
          ]
        }
      ]
    }

    assert {:ok, %{entries: [entry]}} = Parser.parse(Jason.encode!(export), "Spieler")
    assert entry.external_id == "EP9000-PPSA08338_00-GOWRAGNAROK00000"
    assert entry.relationship == :owned
  end
end
