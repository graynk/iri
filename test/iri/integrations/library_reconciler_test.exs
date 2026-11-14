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

defmodule Iri.Integrations.LibraryReconcilerTest do
  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Accounts.Scope
  alias Iri.Integrations.LibraryReconciler
  alias Iri.Library.{GameSource, LibraryItem}

  test "complete uploads reconcile removals while partial history never removes" do
    scope = viewer_user_fixture() |> Scope.for_user()
    attrs = %{external_user_id: "legendary:test", display_name: "Epic"}
    entries = [entry("one"), entry("two")]

    assert {:ok, %{account: account}} =
             LibraryReconciler.import(scope, :epic, attrs, entries, complete: true)

    assert Repo.aggregate(LibraryItem, :count) == 2

    assert {:ok, %{counts: %{removed_count: 1}}} =
             LibraryReconciler.import(scope, :epic, attrs, [entry("one")], complete: true)

    xbox_attrs = %{external_user_id: "xuid", display_name: "Xbox"}

    assert {:ok, %{account: xbox}} =
             LibraryReconciler.import(scope, :xbox, xbox_attrs, [entry("x")], complete: false)

    assert {:ok, %{counts: %{removed_count: 0}}} =
             LibraryReconciler.import(scope, :xbox, xbox_attrs, [], complete: false)

    assert Repo.exists?(
             from item in LibraryItem,
               where: item.provider_account_id == ^xbox.id and is_nil(item.removed_at)
           )

    assert Repo.exists?(
             from source in GameSource,
               where: source.provider == :epic and source.external_id == "one"
           )

    assert account.external_user_id == "legendary:test"
  end

  test "a played-only refresh does not downgrade an existing purchase" do
    scope = viewer_user_fixture() |> Scope.for_user()
    attrs = %{external_user_id: "player", display_name: "PSN player"}

    assert {:ok, %{account: account}} =
             LibraryReconciler.import(scope, :psn, attrs, [entry("astro")], complete: false)

    played = %{entry("astro") | relationship: :played}

    assert {:ok, _result} =
             LibraryReconciler.import(scope, :psn, attrs, [played], complete: false)

    item = Repo.get_by!(LibraryItem, provider_account_id: account.id)
    assert item.relationship == :owned
  end

  test "retire_matching removes stored items that current import rules would filter" do
    scope = viewer_user_fixture() |> Scope.for_user()
    attrs = %{external_user_id: "player", display_name: "PSN player"}

    sketchbook = %{
      external_id: "sketchbook",
      title: "Pragmata Sketchbook",
      relationship: :owned,
      metadata: %{}
    }

    assert {:ok, %{account: account}} =
             LibraryReconciler.import(scope, :psn, attrs, [entry("astro"), sketchbook],
               complete: false
             )

    assert 1 =
             LibraryReconciler.retire_matching(
               account,
               &Iri.Integrations.PSN.Parser.non_game_source?/1
             )

    retired =
      Repo.one!(
        from item in LibraryItem,
          join: source in assoc(item, :game_source),
          where: source.external_id == "sketchbook"
      )

    assert retired.removed_at
    assert %DateTime{} = retired.removed_at

    kept =
      Repo.one!(
        from item in LibraryItem,
          join: source in assoc(item, :game_source),
          where: source.external_id == "astro"
      )

    refute kept.removed_at
  end

  test "a re-uploaded snapshot keeps manual hours but an Xbox re-import refreshes them" do
    scope = viewer_user_fixture() |> Scope.for_user()
    psn_attrs = %{external_user_id: "psn-player", display_name: "PSN player"}

    assert {:ok, %{account: psn}} =
             LibraryReconciler.import(scope, :psn, psn_attrs, [entry("astro")], complete: false)

    psn_item = Repo.get_by!(LibraryItem, provider_account_id: psn.id)
    psn_item |> Ecto.Changeset.change(playtime_minutes: 750) |> Repo.update!()

    assert {:ok, _result} =
             LibraryReconciler.import(scope, :psn, psn_attrs, [entry("astro")], complete: false)

    assert Repo.get!(LibraryItem, psn_item.id).playtime_minutes == 750

    xbox_attrs = %{external_user_id: "xuid", display_name: "Xbox"}
    halo = %{entry("halo") | playtime_minutes: 120}

    assert {:ok, %{account: xbox}} =
             LibraryReconciler.import(scope, :xbox, xbox_attrs, [halo], complete: false)

    xbox_item = Repo.get_by!(LibraryItem, provider_account_id: xbox.id)
    assert xbox_item.playtime_minutes == 120

    assert {:ok, _result} =
             LibraryReconciler.import(scope, :xbox, xbox_attrs, [%{halo | playtime_minutes: 300}],
               complete: false
             )

    assert Repo.get!(LibraryItem, xbox_item.id).playtime_minutes == 300
  end

  defp entry(id),
    do: %{
      external_id: id,
      title: "Game #{id}",
      relationship: :owned,
      playtime_minutes: 0,
      metadata: %{}
    }
end
