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

defmodule Iri.Library.PlaytimeTest do
  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Accounts.{Scope, User}
  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{Game, GameSource, LibraryItem, Playtime}

  test "a user's own Steam account counts even without a chosen main account" do
    user = %User{id: 1, main_steam_account_id: nil, steam_id: nil}
    owned = %ProviderAccount{provider: :steam, owner_user_id: 1}

    assert Playtime.personal_account?(owned, user)
  end

  test "another user's Steam account never counts as the fallback" do
    user = %User{id: 1, main_steam_account_id: nil, steam_id: nil}
    shared = %ProviderAccount{provider: :steam, owner_user_id: 2}

    refute Playtime.personal_account?(shared, user)
  end

  test "the chosen main Steam account is honored over the fallback" do
    user = %User{id: 1, main_steam_account_id: 42, steam_id: nil}
    main = %ProviderAccount{id: 42, provider: :steam, owner_user_id: 1}
    other_owned = %ProviderAccount{id: 43, provider: :steam, owner_user_id: 1}

    assert Playtime.personal_account?(main, user)
    # With a main chosen, a different owned Steam account is not counted.
    refute Playtime.personal_account?(other_owned, user)
  end

  test "a linked Steam identity is matched by steam_id" do
    user = %User{id: 1, main_steam_account_id: nil, steam_id: "7656119"}
    linked = %ProviderAccount{provider: :steam, external_user_id: "7656119", owner_user_id: 2}

    assert Playtime.personal_account?(linked, user)
  end

  test "non-Steam accounts count when owned by the user" do
    user = %User{id: 1, main_steam_account_id: nil, steam_id: nil}
    gog = %ProviderAccount{provider: :gog, owner_user_id: 1}

    assert Playtime.personal_account?(gog, user)
    refute Playtime.personal_account?(%ProviderAccount{provider: :gog, owner_user_id: 2}, user)
  end

  test "only stores that report their own hours are self-reported" do
    for provider <- [:steam, :gog, :xbox], do: assert(Playtime.self_reported?(provider))
    for provider <- [:custom, :epic, :psn], do: refute(Playtime.self_reported?(provider))
  end

  test "a personal item is editable only on a store that reports no hours" do
    user = %User{id: 1, main_steam_account_id: nil, steam_id: nil}

    assert Playtime.editable?(%ProviderAccount{provider: :psn, owner_user_id: 1}, user)
    assert Playtime.editable?(%ProviderAccount{provider: :custom, owner_user_id: 1}, user)
    refute Playtime.editable?(%ProviderAccount{provider: :steam, owner_user_id: 1}, user)
    refute Playtime.editable?(%ProviderAccount{provider: :gog, owner_user_id: 1}, user)
    # Someone else's PSN account is not the viewer's to edit.
    refute Playtime.editable?(%ProviderAccount{provider: :psn, owner_user_id: 2}, user)
  end

  test "set_minutes records and clears hours on a store that reports none" do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)
    game = game_fixture("astro-bot")
    item = item_fixture(user, game, :psn, "psn-astro")

    assert {:ok, 750} = Playtime.set_minutes(scope, game.id, 750)
    assert Repo.get!(LibraryItem, item.id).playtime_minutes == 750

    assert {:ok, 0} = Playtime.set_minutes(scope, game.id, 0)
    assert Repo.get!(LibraryItem, item.id).playtime_minutes == 0
  end

  test "set_minutes writes every editable personal item for the same game" do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)
    game = game_fixture("multi-store")
    psn_item = item_fixture(user, game, :psn, "psn-multi")
    epic_item = item_fixture(user, game, :epic, "epic-multi")

    assert {:ok, 600} = Playtime.set_minutes(scope, game.id, 600)
    assert Repo.get!(LibraryItem, psn_item.id).playtime_minutes == 600
    assert Repo.get!(LibraryItem, epic_item.id).playtime_minutes == 600
  end

  test "set_minutes refuses a game owned only on a store that reports its own hours" do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)
    game = game_fixture("half-life")
    item = item_fixture(user, game, :steam, "steam-hl")

    assert {:error, :not_editable} = Playtime.set_minutes(scope, game.id, 120)
    assert Repo.get!(LibraryItem, item.id).playtime_minutes == 0
  end

  test "set_minutes refuses a game the viewer cannot see" do
    owner = viewer_user_fixture()
    stranger = viewer_user_fixture()
    game = game_fixture("private-game")
    item = item_fixture(owner, game, :psn, "psn-private")

    assert {:error, :not_found} = Playtime.set_minutes(Scope.for_user(stranger), game.id, 120)
    assert Repo.get!(LibraryItem, item.id).playtime_minutes == 0
  end

  defp game_fixture(slug) do
    %Game{}
    |> Game.changeset(%{
      title: slug,
      normalized_title: slug,
      slug: slug
    })
    |> Repo.insert!()
  end

  defp item_fixture(user, game, provider, external_id) do
    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: provider,
        external_user_id: "#{external_id}-account",
        display_name: "#{provider} account",
        sharing_policy: :selected_users
      })
      |> Ecto.Changeset.put_change(:owner_user_id, user.id)
      |> Repo.insert!()

    source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: provider,
        external_id: external_id,
        source_title: game.title,
        normalized_source_title: game.normalized_title,
        game_id: game.id,
        catalog_kind: "game"
      })
      |> Repo.insert!()

    %LibraryItem{}
    |> LibraryItem.changeset(%{
      provider_account_id: account.id,
      game_source_id: source.id
    })
    |> Repo.insert!()
  end
end
