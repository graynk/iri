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

defmodule Iri.Library.CompaniesTest do
  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Accounts.Scope
  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{Companies, Company, Game, GameCompany, GameSource, LibraryItem}

  test "lists canonical company games across connected and Family-shared stores" do
    viewer = viewer_user_fixture()
    family_owner = viewer_user_fixture()
    private_owner = viewer_user_fixture()

    steam = account_fixture(family_owner, :steam, :inherit)
    gog = account_fixture(family_owner, :gog, :inherit)
    private = account_fixture(private_owner, :steam, :selected_users)

    studio = company_fixture("Across Stores Studio")
    private_studio = company_fixture("Private Studio")

    alpha = game_fixture("Alpha")
    beta = game_fixture("Beta")
    hidden = game_fixture("Hidden From Viewer")

    alpha
    |> source_fixture(steam, :steam)
    |> source_fixture(gog, :gog)

    source_fixture(beta, steam, :steam)
    source_fixture(hidden, private, :steam)

    company_relation_fixture(alpha, studio, "developer")
    company_relation_fixture(beta, studio, "publisher")
    company_relation_fixture(hidden, studio, "developer")
    company_relation_fixture(hidden, private_studio, "publisher")

    assert {:ok, result} = Companies.get_in_library(Scope.for_user(viewer), studio.id)

    assert result.company.id == studio.id
    assert result.total_count == 2
    assert Enum.map(result.games, & &1.title) == ["Alpha", "Beta"]

    loaded_alpha = Enum.find(result.games, &(&1.id == alpha.id))
    assert Enum.map(loaded_alpha.sources, & &1.provider) |> Enum.sort() == [:gog, :steam]
    assert Enum.all?(loaded_alpha.sources, &match?([%LibraryItem{}], &1.library_items))

    assert {:error, :not_found} =
             Companies.get_in_library(Scope.for_user(viewer), private_studio.id)

    assert {:error, :not_found} = Companies.get_in_library(Scope.for_user(viewer), "invalid")
    assert {:error, :unauthorized} = Companies.get_in_library(nil, studio.id)
  end

  defp account_fixture(owner, provider, sharing_policy) do
    unique = System.unique_integer([:positive])

    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: provider,
      external_user_id: "company-#{provider}-#{unique}",
      display_name: "#{provider} library",
      sharing_policy: sharing_policy
    })
    |> Ecto.Changeset.put_change(:owner_user_id, owner.id)
    |> Repo.insert!()
  end

  defp company_fixture(name) do
    unique = System.unique_integer([:positive])

    %Company{}
    |> Company.changeset(%{
      source: "igdb",
      external_id: "company-#{unique}",
      name: name,
      slug: Iri.Library.Title.slug(name)
    })
    |> Repo.insert!()
  end

  defp game_fixture(title) do
    unique = System.unique_integer([:positive])

    %Game{}
    |> Game.changeset(%{
      title: title,
      normalized_title: Iri.Library.Title.normalize(title),
      slug: "#{Iri.Library.Title.slug(title)}-#{unique}",
      release_year: 2020 + rem(unique, 6)
    })
    |> Repo.insert!()
  end

  defp source_fixture(%Game{} = game, %ProviderAccount{} = account, provider) do
    unique = System.unique_integer([:positive])

    source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: provider,
        external_id: "company-game-#{provider}-#{unique}",
        game_id: game.id,
        source_title: game.title,
        normalized_source_title: game.normalized_title
      })
      |> Repo.insert!()

    %LibraryItem{}
    |> LibraryItem.changeset(%{
      provider_account_id: account.id,
      game_source_id: source.id
    })
    |> Repo.insert!()

    game
  end

  defp company_relation_fixture(game, company, role) do
    %GameCompany{}
    |> GameCompany.changeset(%{
      game_id: game.id,
      company_id: company.id,
      role: role
    })
    |> Repo.insert!()
  end
end
