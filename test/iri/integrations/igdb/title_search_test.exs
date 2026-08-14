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

defmodule Iri.Integrations.IGDB.TitleSearchTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.IGDB.TitleSearch

  test "removes storefront symbols and known edition suffixes" do
    assert TitleSearch.terms("Batman™ Arkham Asylum Game of the Year Edition") == [
             "Batman Arkham Asylum",
             "Batman Arkham Asylum Game of the Year Edition"
           ]

    assert TitleSearch.terms("Call of Duty®") == ["Call of Duty"]

    assert TitleSearch.terms("Fixture (R) [TM] {SM} GameⓇ") == ["Fixture Game"]
  end

  test "preserves identity-bearing definitive-edition titles" do
    assert TitleSearch.terms("Mafia: Definitive Edition") == [
             "Mafia: Definitive Edition",
             "Mafia Definitive Edition"
           ]
  end

  test "tries a punctuation-neutral spelling for catalog typography" do
    assert TitleSearch.terms("Tomb Raider IV-VI Remastered") == [
             "Tomb Raider IV-VI Remastered",
             "Tomb Raider IV VI Remastered"
           ]
  end

  test "tries IGDB's colon spelling for storefront dash separators" do
    assert TitleSearch.terms("Divinity II - The Dragon Knight Saga") == [
             "Divinity II - The Dragon Knight Saga",
             "Divinity II: The Dragon Knight Saga",
             "Divinity II The Dragon Knight Saga"
           ]
  end

  test "removes known promotional subtitles" do
    assert TitleSearch.terms("ATOM RPG: Post-apocalyptic indie game") == [
             "ATOM RPG",
             "ATOM RPG: Post-apocalyptic indie game"
           ]
  end
end
