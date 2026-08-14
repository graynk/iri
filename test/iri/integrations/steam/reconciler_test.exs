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

defmodule Iri.Integrations.Steam.ReconcilerTest do
  use Iri.DataCase

  alias Iri.Integrations.ProviderAccount
  alias Iri.Integrations.Steam.Reconciler
  alias Iri.Library.{GameSource, LibraryItem}

  test "imports playtime and repeats idempotently" do
    account = steam_account_fixture()

    assert {:ok, first_counts} = Reconciler.reconcile(account, games_fixture())

    assert first_counts == %{
             discovered_count: 2,
             inserted_count: 2,
             updated_count: 0,
             removed_count: 0,
             new_source_count: 2
           }

    assert Repo.aggregate(GameSource, :count) == 2
    assert Repo.aggregate(LibraryItem, :count) == 2

    updated_games =
      Enum.map(games_fixture(), fn
        %{"appid" => 10} = game -> %{game | "playtime_forever" => 600}
        game -> game
      end)

    assert {:ok, second_counts} = Reconciler.reconcile(account, updated_games)
    assert second_counts.inserted_count == 0
    assert second_counts.updated_count == 2
    assert Repo.aggregate(GameSource, :count) == 2
    assert Repo.aggregate(LibraryItem, :count) == 2

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "10")
    item = Repo.get_by!(LibraryItem, provider_account_id: account.id, game_source_id: source.id)
    assert item.playtime_minutes == 600
  end

  test "marks absent games removed only after a complete non-empty response" do
    account = steam_account_fixture()
    assert {:ok, _counts} = Reconciler.reconcile(account, games_fixture())

    assert {:ok, counts} = Reconciler.reconcile(account, [List.first(games_fixture())])
    assert counts.removed_count == 1

    assert Repo.aggregate(from(item in LibraryItem, where: not is_nil(item.removed_at)), :count) ==
             1

    assert {:error, :incomplete_library} = Reconciler.reconcile(account, [])
    assert Repo.aggregate(from(item in LibraryItem, where: is_nil(item.removed_at)), :count) == 1
  end

  test "invalid payload aborts without modifying valid ownership" do
    account = steam_account_fixture()
    assert {:ok, _counts} = Reconciler.reconcile(account, games_fixture())

    assert {:error, :invalid_game_payload} =
             Reconciler.reconcile(account, [%{"appid" => "not-an-integer"}])

    assert Repo.aggregate(from(item in LibraryItem, where: is_nil(item.removed_at)), :count) == 2
  end

  defp steam_account_fixture do
    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: :steam,
      external_user_id: "76561198000000001",
      display_name: "Fixture player"
    })
    |> Repo.insert!()
  end

  defp games_fixture do
    [
      %{
        "appid" => 10,
        "name" => "Counter-Strike",
        "playtime_forever" => 180,
        "playtime_windows_forever" => 120,
        "rtime_last_played" => 1_700_000_000
      },
      %{"appid" => 20, "name" => "Team Fortress Classic", "playtime_forever" => 0}
    ]
  end
end
