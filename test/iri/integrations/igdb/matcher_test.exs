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

defmodule Iri.Integrations.IGDB.MatcherTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.IGDB.Matcher
  alias Iri.Library.GameSource

  test "selects one identical PC title for automatic matching" do
    ranked =
      Matcher.rank("Mystery Game", [
        candidate(1, "Mystery Game", true),
        candidate(2, "Mystery Game Remastered", true)
      ])

    assert {:ok, %{igdb_id: 1, score: 1.0}} = Matcher.automatic_candidate(ranked)
  end

  test "console imports can auto-match one exact title on the corresponding platform" do
    psn = [%{"id" => 1, "name" => "Astro Bot", "platforms" => [%{"name" => "PlayStation 5"}]}]
    xbox = [%{"id" => 2, "name" => "Halo", "platforms" => [%{"name" => "Xbox Series X|S"}]}]

    assert {:ok, %{igdb_id: 1}} =
             Matcher.rank("Astro Bot", psn, provider: :psn) |> Matcher.automatic_candidate()

    assert {:ok, %{igdb_id: 2}} =
             Matcher.rank("Halo", xbox, provider: :xbox) |> Matcher.automatic_candidate()
  end

  test "requires review when multiple identical PC titles exist" do
    ranked =
      Matcher.rank("Mystery Game", [
        candidate(1, "Mystery Game", true),
        candidate(2, "Mystery Game", true)
      ])

    assert :review = Matcher.automatic_candidate(ranked)
  end

  test "uses provider platform metadata to disambiguate an exact console title" do
    ranked =
      Matcher.rank(
        "Judgment",
        [
          candidate(109_274, "Judgment", ["PlayStation 4"]),
          candidate(281_562, "Judgment", ["PlayStation 5"])
        ],
        provider: :psn
      )

    source = %GameSource{
      provider: :psn,
      metadata_snapshot: %{"psn" => %{"platform" => "PS5"}}
    }

    assert {:ok, %{igdb_id: 281_562}} = Matcher.automatic_candidate(ranked, source: source)
  end

  test "uses provider company metadata to disambiguate identical PC titles" do
    ranked =
      Matcher.rank("Pathway", [
        company_candidate(26_597, "Pathway", "Robotality", :developer),
        company_candidate(99_999, "Pathway", "Studio CloudScape", :developer)
      ])

    source = %GameSource{
      provider: :epic,
      metadata_snapshot: %{"legendary" => %{"developer" => "Robotality"}}
    }

    assert {:ok, %{igdb_id: 26_597}} = Matcher.automatic_candidate(ranked, source: source)
  end

  test "normalizes company suffixes and considers publishers" do
    ranked =
      Matcher.rank("The Messenger", [
        company_candidate(71_628, "The Messenger", "Devolver Digital", :publisher),
        company_candidate(44_838, "The Messenger", "Arxel Tribe", :developer)
      ])

    source = %GameSource{
      provider: :epic,
      metadata_snapshot: %{"legendary" => %{"developer" => "Devolver Digital, Inc."}}
    }

    assert {:ok, %{igdb_id: 71_628}} = Matcher.automatic_candidate(ranked, source: source)
  end

  test "keeps review when provider metadata does not distinguish exact candidates" do
    ranked =
      Matcher.rank("Layers of Fear", [
        company_candidate(1, "Layers of Fear", "Bloober Team", :developer),
        company_candidate(2, "Layers of Fear", "Bloober Team", :developer)
      ])

    source = %GameSource{
      provider: :epic,
      metadata_snapshot: %{"legendary" => %{"developer" => "Bloober Team"}}
    }

    assert :review = Matcher.automatic_candidate(ranked, source: source)
  end

  test "never promotes a merely fuzzy title to a perfect match" do
    assert [%{score: score}] = Matcher.rank("Mystery Game", [candidate(1, "Mystery Games", true)])
    assert score < 1.0
  end

  test "treats known store edition labels and promotional subtitles as title noise" do
    assert [%{score: 1.0}] =
             Matcher.rank("Batman™ Arkham Asylum Game of the Year Edition", [
               candidate(1, "Batman Arkham Asylum", true)
             ])

    assert [%{score: 1.0}] =
             Matcher.rank("ATOM RPG: Post-apocalyptic indie game", [
               candidate(2, "ATOM RPG", true)
             ])
  end

  test "does not collapse Mafia Definitive Edition into the original game" do
    ranked =
      Matcher.rank("Mafia: Definitive Edition", [
        candidate(1, "Mafia", true),
        candidate(2, "Mafia: Definitive Edition", true)
      ])

    assert {:ok, %{igdb_id: 2}} = Matcher.automatic_candidate(ranked)
    assert Enum.find(ranked, &(&1.igdb_id == 1)).score < 1.0
  end

  test "keeps presentation metadata for manual review" do
    payload =
      candidate(1, "Mystery Game", true)
      |> Map.merge(%{
        "summary" => "A useful description.",
        "first_release_date" => 1_600_000_000,
        "game_type" => %{"type" => "Main Game"},
        "involved_companies" => [
          %{"developer" => true, "company" => %{"name" => "Fixture Studio"}}
        ]
      })

    assert [%{metadata: metadata}] = Matcher.rank("Mystery Game", [payload])
    assert metadata["summary"] == "A useful description."
    assert metadata["first_release_date"] == 1_600_000_000

    assert get_in(metadata, ["involved_companies", Access.at(0), "company", "name"]) ==
             "Fixture Studio"
  end

  defp candidate(id, name, pc?) when is_boolean(pc?) do
    platforms = if pc?, do: [%{"name" => "PC (Microsoft Windows)"}], else: []
    %{"id" => id, "name" => name, "platforms" => platforms}
  end

  defp candidate(id, name, platforms) when is_list(platforms) do
    %{"id" => id, "name" => name, "platforms" => Enum.map(platforms, &%{"name" => &1})}
  end

  defp company_candidate(id, name, company, role) do
    role_flags = %{
      "developer" => role == :developer,
      "publisher" => role == :publisher
    }

    %{
      "id" => id,
      "name" => name,
      "platforms" => [%{"name" => "PC (Microsoft Windows)"}],
      "involved_companies" => [
        Map.merge(role_flags, %{"company" => %{"name" => company}})
      ]
    }
  end
end
