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

defmodule Iri.Integrations.GOG.ReconcilerTest do
  use Iri.DataCase

  alias Iri.Integrations.GOG.{ClientStub, Reconciler}
  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{GameSource, LibraryItem}

  test "reconciles GOG metadata, personal state, and removals idempotently" do
    account = gog_account_fixture()
    assert {:ok, games} = ClientStub.fetch_library(account, %{}, [])

    assert {:ok, first} = Reconciler.reconcile(account, games)
    assert first.discovered_count == 2
    assert first.inserted_count == 2

    source = Repo.get_by!(GameSource, provider: :gog, external_id: "30")
    item = Repo.get_by!(LibraryItem, game_source_id: source.id)
    refute item.hidden
    assert item.playtime_minutes == 0
    assert source.source_url =~ "gog.com/game/"

    assert {:ok, second} = Reconciler.reconcile(account, games)
    assert second.inserted_count == 0
    assert second.updated_count == 2

    assert {:ok, third} = Reconciler.reconcile(account, Enum.take(games, 1))
    assert third.removed_count == 1
    assert Repo.get!(LibraryItem, item.id).removed_at

    assert {:ok, fourth} = Reconciler.reconcile(account, [])
    assert fourth.discovered_count == 0
    assert fourth.removed_count == 1
    assert Repo.aggregate(from(item in LibraryItem, where: is_nil(item.removed_at)), :count) == 0
  end

  defp gog_account_fixture do
    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: :gog,
      external_user_id: "48628349971017",
      display_name: "GOG owner"
    })
    |> Repo.insert!()
  end
end
