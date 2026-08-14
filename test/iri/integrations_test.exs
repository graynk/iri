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

defmodule Iri.IntegrationsTest do
  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Accounts
  alias Iri.Accounts.Scope
  alias Iri.Integrations
  alias Iri.Integrations.ProviderAccount
  alias Iri.Integrations.GOG.ClientStub, as: GOGClientStub
  alias Iri.Integrations.IGDB.{ClientStub, TokenManager}
  alias Iri.Integrations.Steam.ClientStub, as: SteamClientStub
  alias Iri.Integrations.Steam.Reconciler
  alias Iri.Library.{Game, GameSource, Playtime}

  test "provider accounts belong to the user who connects them" do
    owner = viewer_user_fixture()
    other = viewer_user_fixture()

    assert {:ok, %{account: account}} =
             Integrations.connect_gog(Scope.for_user(owner), %{"profile" => "fixture-gog"},
               client: GOGClientStub
             )

    assert account.owner_user_id == owner.id
    assert {:ok, [listed]} = Integrations.list_provider_accounts(Scope.for_user(owner))
    assert listed.id == account.id
    assert {:ok, []} = Integrations.list_provider_accounts(Scope.for_user(other))

    # A later connect by someone else follows the account instead of failing;
    # ownership and playtime credit stay with the first user.
    assert {:ok, %{account: followed, followed: true}} =
             Integrations.connect_gog(Scope.for_user(other), %{"profile" => "fixture-gog"},
               client: GOGClientStub
             )

    assert followed.owner_user_id == owner.id
    assert Enum.map(followed.shared_users, & &1.id) == [other.id]
  end

  test "visibility grants do not become user-linked integration accounts" do
    owner = viewer_user_fixture()
    viewer = viewer_user_fixture()

    {:ok, account} =
      Integrations.create_provider_account(Scope.for_user(owner), %{
        provider: :steam,
        external_user_id: "76561198000000041"
      })

    assert {:ok, _account} =
             Integrations.update_provider_account_access(Scope.for_user(owner), account.id, %{
               "sharing_policy" => "selected_users",
               "shared_user_ids" => [viewer.id]
             })

    assert {:ok, []} = Integrations.list_provider_accounts(Scope.for_user(viewer))

    assert {:error, :not_found} =
             Accounts.set_main_steam_account(Scope.for_user(viewer), account.id)
  end

  test "GOG uses a public profile and persists no credential record" do
    scope = viewer_user_fixture() |> Scope.for_user()

    assert {:ok, %{account: account, game_count: 2}} =
             Integrations.connect_gog(scope, %{"profile" => "https://www.gog.com/u/fixture-gog"},
               client: GOGClientStub,
               client_options: [test_pid: self()]
             )

    assert_received :gog_profile_validated
    assert account.external_user_id == "fixture-gog"

    refute Repo.exists?(
             from table in "sqlite_master",
               where:
                 field(table, :type) == "table" and field(table, :name) == "provider_credentials"
           )
  end

  test "a single manually linked Steam account becomes personal for every linker" do
    first_user = viewer_user_fixture()
    second_user = viewer_user_fixture()
    steam_id = "76561198000000021"

    assert {:ok, %{account: account, user: updated_first}} =
             Integrations.connect_steam(
               Scope.for_user(first_user),
               %{"profile" => steam_id},
               client: SteamClientStub
             )

    assert updated_first.main_steam_account_id == account.id
    assert Playtime.personal_account?(account, updated_first)

    assert {:ok, %{account: followed, followed: true, user: updated_second}} =
             Integrations.connect_steam(
               Scope.for_user(second_user),
               %{"profile" => steam_id},
               client: SteamClientStub
             )

    assert updated_second.main_steam_account_id == account.id
    assert Playtime.personal_account?(followed, updated_second)
    assert {:ok, [listed]} = Integrations.list_provider_accounts(Scope.for_user(updated_second))
    assert listed.id == account.id
  end

  test "a user can choose a main Steam account without claiming its login identity" do
    user = viewer_user_fixture()
    other_owner = viewer_user_fixture()

    assert {:ok, %{account: first, user: user}} =
             Integrations.connect_steam(
               Scope.for_user(user),
               %{"profile" => "76561198000000031"},
               client: SteamClientStub
             )

    assert {:ok, %{account: second}} =
             Integrations.connect_steam(
               Scope.for_user(other_owner),
               %{"profile" => "76561198000000032"},
               client: SteamClientStub
             )

    assert {:ok, %{followed: true}} =
             Integrations.connect_steam(
               Scope.for_user(user),
               %{"profile" => second.external_user_id},
               client: SteamClientStub
             )

    assert {:ok, selected} =
             Accounts.set_main_steam_account(Scope.for_user(user), second.id)

    assert selected.main_steam_account_id == second.id
    assert selected.steam_id == nil
    refute Playtime.personal_account?(first, selected)
    assert Playtime.personal_account?(second, selected)
  end

  test "runtime API key status is visible but key values are never returned by UI helpers" do
    scope = viewer_user_fixture() |> Scope.for_user()
    assert {:ok, true} = Integrations.steam_api_key_configured?(scope)
    assert {:ok, true} = Integrations.igdb_configured?(scope)
  end

  test "a user cannot update or delete another user's provider account" do
    owner = viewer_user_fixture()
    other = viewer_user_fixture()

    {:ok, account} =
      Integrations.create_provider_account(Scope.for_user(owner), %{
        provider: :steam,
        external_user_id: "76561198000000001"
      })

    assert {:error, :not_found} =
             Integrations.delete_provider_account(Scope.for_user(other), account.id)

    assert {:error, :not_found} =
             Integrations.update_provider_account_access(Scope.for_user(other), account.id, %{
               "sharing_policy" => "everyone"
             })
  end

  test "IGDB token is cached and contains required store source IDs" do
    :ok = TokenManager.reset()
    assert {:ok, first} = Integrations.igdb_credentials_for_sync(ClientStub, test_pid: self())
    assert_received :igdb_authenticated
    assert first["steam_source_id"] == 1
    assert first["gog_source_id"] == 5
    assert {:ok, second} = Integrations.igdb_credentials_for_sync(ClientStub, test_pid: self())
    refute_receive :igdb_authenticated
    assert second["access_token"] == first["access_token"]
  end

  test "deleting an owned account removes it" do
    scope = viewer_user_fixture() |> Scope.for_user()

    {:ok, account} =
      Integrations.create_provider_account(scope, %{
        provider: :steam,
        external_user_id: "76561198000000001"
      })

    assert {:ok, {deleted, _pruned}} = Integrations.delete_provider_account(scope, account.id)
    assert deleted.id == account.id
    refute Repo.get(ProviderAccount, account.id)
  end

  test "deleting the last account holding a game drops the game and its sources" do
    scope = viewer_user_fixture() |> Scope.for_user()

    {:ok, account} =
      Integrations.create_provider_account(scope, %{
        provider: :steam,
        external_user_id: "76561198000000002"
      })

    assert {:ok, _counts} = Reconciler.reconcile(account, [%{"appid" => 10, "name" => "Orphan"}])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "10")
    game = Repo.insert!(%Game{title: "Orphan", normalized_title: "orphan", slug: "orphan"})
    source |> Ecto.Changeset.change(game_id: game.id) |> Repo.update!()

    assert {:ok, {_deleted, pruned}} = Integrations.delete_provider_account(scope, account.id)

    assert pruned.games == 1
    assert pruned.sources == 1
    refute Repo.get(Game, game.id)
    refute Repo.get(GameSource, source.id)
  end

  test "a game still held by another account survives the deletion" do
    owner = viewer_user_fixture() |> Scope.for_user()
    keeper = viewer_user_fixture() |> Scope.for_user()

    {:ok, leaving} =
      Integrations.create_provider_account(owner, %{
        provider: :steam,
        external_user_id: "76561198000000003"
      })

    {:ok, staying} =
      Integrations.create_provider_account(keeper, %{
        provider: :steam,
        external_user_id: "76561198000000004"
      })

    for account <- [leaving, staying] do
      assert {:ok, _counts} =
               Reconciler.reconcile(account, [%{"appid" => 20, "name" => "Shared"}])
    end

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "20")

    assert {:ok, {_deleted, pruned}} = Integrations.delete_provider_account(owner, leaving.id)

    assert pruned.sources == 0
    assert Repo.get(GameSource, source.id)
  end
end
