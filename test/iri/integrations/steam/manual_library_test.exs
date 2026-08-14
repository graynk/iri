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

defmodule Iri.Integrations.Steam.ManualLibraryTest do
  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Accounts.{Scope, User}
  alias Iri.Integrations.ProviderAccount
  alias Iri.Integrations.Steam.{AppDetailsClientStub, ManualLibrary, Reconciler}
  alias Iri.Library.{GameSource, LibraryItem}

  test "adds an omitted Steam AppID and preserves it across complete API snapshots" do
    user = viewer_user_fixture()
    account = steam_account_fixture(user)
    scope = user |> select_main_account(account) |> Scope.for_user()

    assert {:ok, %{status: :added, source: source}} =
             ManualLibrary.add(scope, "https://store.steampowered.com/app/2771670/",
               client: AppDetailsClientStub,
               enqueue_enrichment: false
             )

    item = Repo.get_by!(LibraryItem, provider_account_id: account.id, game_source_id: source.id)
    assert item.manually_added

    assert {:ok, counts} =
             Reconciler.reconcile(account, [
               %{"appid" => 10, "name" => "Counter-Strike", "playtime_forever" => 0}
             ])

    assert counts.removed_count == 0
    item = Repo.reload!(item)
    refute item.removed_at
    assert is_nil(item.removed_at)

    assert {:ok, %{removed: 1}} = ManualLibrary.remove(scope, source.id)
    refute Repo.get(LibraryItem, item.id)
    refute Repo.get(GameSource, source.id)
  end

  test "requires a selected or unambiguous linked Steam account" do
    scope = viewer_user_fixture() |> Scope.for_user()

    assert {:error, :steam_account_required} =
             ManualLibrary.add(scope, "2771670",
               client: AppDetailsClientStub,
               enqueue_enrichment: false
             )
  end

  test "parses AppIDs without accepting unrelated text" do
    assert {:ok, "1603980"} = ManualLibrary.parse_app_id("1603980")

    assert {:ok, "1603980"} =
             ManualLibrary.parse_app_id(
               "https://store.steampowered.com/app/1603980/If_On_A_Winters_Night_Four_Travelers/"
             )

    assert {:error, :invalid_app_id} = ManualLibrary.parse_app_id("not a Steam game")
    assert {:error, :invalid_app_id} = ManualLibrary.parse_app_id("unrelated text 1603980")
  end

  defp steam_account_fixture(user) do
    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: :steam,
      external_user_id: "76561198000000001",
      display_name: "Fixture player"
    })
    |> Ecto.Changeset.put_change(:owner_user_id, user.id)
    |> Repo.insert!()
  end

  defp select_main_account(user, account) do
    user
    |> User.main_steam_account_changeset(account.id)
    |> Repo.update!()
  end
end
