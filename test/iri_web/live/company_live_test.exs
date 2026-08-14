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

defmodule IriWeb.CompanyLiveTest do
  use IriWeb.ConnCase

  import Iri.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{Company, Game, GameCompany, GameSource, LibraryItem}
  alias Iri.Repo

  test "anonymous visitors are redirected to login", %{conn: conn} do
    # An instance that already has an account sends anonymous visitors to log
    # in; a fresh instance sends them to registration instead.
    _existing = viewer_user_fixture()

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(conn, ~p"/companies/1")
  end

  test "developer and publisher links open accessible games across stores", %{conn: conn} do
    viewer = viewer_user_fixture()
    family_owner = viewer_user_fixture()
    private_owner = viewer_user_fixture()

    steam = account_fixture(family_owner, :steam, :inherit)
    gog = account_fixture(family_owner, :gog, :inherit)
    private = account_fixture(private_owner, :steam, :selected_users)

    company = company_fixture("Fixture Collective")
    alpha = game_fixture("Alpha Across Stores", 2024)
    beta = game_fixture("Beta Shared Game", 2021)
    inaccessible = game_fixture("Private Company Game", 2025)

    add_source(alpha, steam, :steam)
    add_source(alpha, gog, :gog)
    add_source(beta, steam, :steam)
    add_source(inaccessible, private, :steam)

    alpha_relation = company_relation_fixture(alpha, company, "developer")
    beta_relation = company_relation_fixture(beta, company, "publisher")
    company_relation_fixture(inaccessible, company, "developer")

    logged_in_conn = log_in_user(conn, viewer)
    {:ok, detail, _html} = live(logged_in_conn, ~p"/games/#{alpha.slug}")

    assert has_element?(
             detail,
             "#game-company-#{alpha_relation.id}[href='/companies/#{company.id}']",
             company.name
           )

    {:ok, publisher_detail, _html} = live(logged_in_conn, ~p"/games/#{beta.slug}")

    assert has_element?(
             publisher_detail,
             "#game-company-#{beta_relation.id}[href='/companies/#{company.id}']",
             company.name
           )

    {:ok, company_view, _html} = live(logged_in_conn, ~p"/companies/#{company.id}")

    assert has_element?(company_view, "#company-page")
    assert has_element?(company_view, "#company-name", company.name)
    assert has_element?(company_view, "#company-roles", "Developer & Publisher")
    assert has_element?(company_view, "#company-game-count", "2 games")

    assert has_element?(
             company_view,
             "#company-game-link-#{alpha.id}[href='/games/#{alpha.slug}']",
             alpha.title
           )

    assert has_element?(
             company_view,
             "#company-game-link-#{beta.id}[href='/games/#{beta.slug}']",
             beta.title
           )

    assert has_element?(company_view, "#company-game-#{alpha.id}", "steam")
    assert has_element?(company_view, "#company-game-#{alpha.id}", "gog")
    assert has_element?(company_view, "#company-game-#{alpha.id}", "Developer")
    assert has_element?(company_view, "#company-game-#{beta.id}", "Publisher")
    refute has_element?(company_view, "#company-game-#{inaccessible.id}")
  end

  defp account_fixture(owner, provider, sharing_policy) do
    unique = System.unique_integer([:positive])

    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: provider,
      external_user_id: "company-live-#{provider}-#{unique}",
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
      external_id: "company-live-#{unique}",
      name: name,
      slug: Iri.Library.Title.slug(name)
    })
    |> Repo.insert!()
  end

  defp game_fixture(title, release_year) do
    unique = System.unique_integer([:positive])

    %Game{}
    |> Game.changeset(%{
      title: title,
      normalized_title: Iri.Library.Title.normalize(title),
      slug: "#{Iri.Library.Title.slug(title)}-#{unique}",
      release_year: release_year
    })
    |> Repo.insert!()
  end

  defp add_source(game, account, provider) do
    unique = System.unique_integer([:positive])

    source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: provider,
        external_id: "company-live-game-#{provider}-#{unique}",
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
