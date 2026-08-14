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

defmodule Iri.MatchesTest do
  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Accounts.Scope
  alias Iri.Integrations.IGDB.ClientStub
  alias Iri.Integrations.VNDB.ClientStub, as: VNDBClientStub
  alias Iri.Integrations.{LibraryReconciler, ProviderAccount}
  alias Iri.Integrations.Steam.Reconciler
  alias Iri.Library.{Game, GameSource, LibraryItem, MatchCandidate}
  alias Iri.Library
  alias Iri.Matches
  alias Iri.Matches.MatchDecision

  test "an unresolved source requires an explicit candidate choice" do
    scope = admin_user_fixture() |> Scope.for_user()
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 99, "name" => "Mystery Game"}])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "99")

    assert {:ok, source} = Matches.find_candidates(scope, source.id, client: ClientStub)
    assert [%MatchCandidate{igdb_id: 90_001}] = source.match_candidates
    refute Repo.get!(GameSource, source.id).game_id

    assert {:ok, matched} =
             Matches.apply_candidate(scope, source.id, 90_001,
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    assert matched.manual_lock
    assert matched.match_method == "manual"
    assert matched.game_id
    assert Repo.get!(Game, matched.game_id).igdb_id == 90_001
    assert Repo.aggregate(MatchCandidate, :count) == 0

    assert {:ok, [resolved]} = Matches.list_resolved_sources(scope)
    assert resolved.id == matched.id
    assert resolved.game.id == matched.game_id
  end

  test "current decisions include locked sources created before audit history" do
    scope = admin_user_fixture() |> Scope.for_user()
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 106, "name" => "Legacy Decision"}])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "106")

    source
    |> GameSource.changeset(%{manual_lock: true, match_method: "ignored"})
    |> Repo.update!()

    assert Repo.aggregate(MatchDecision, :count) == 0
    assert {:ok, [resolved]} = Matches.list_resolved_sources(scope)
    assert resolved.id == source.id
  end

  test "ignore is persisted as a locked store-only decision" do
    scope = admin_user_fixture() |> Scope.for_user()
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 100, "name" => "No Match"}])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "100")

    assert {:ok, ignored} = Matches.ignore_source(scope, source.id)
    assert ignored.manual_lock
    assert ignored.match_method == "ignored"
    refute ignored.game_id
    assert {:ok, 0} = Matches.count_queue(scope)
  end

  test "reject hides a non-game reversibly without destroying ownership" do
    scope = admin_user_fixture() |> Scope.for_user()
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 104, "name" => "Beta, Public Test"}])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "104")
    source |> GameSource.changeset(%{catalog_kind: "game"}) |> Repo.update!()

    assert {:ok, rejected} = Matches.reject_source(scope, source.id)
    assert rejected.manual_lock
    assert rejected.match_method == "rejected"
    assert rejected.catalog_kind == "rejected"

    item = Repo.get_by!(LibraryItem, provider_account_id: account.id, game_source_id: source.id)
    refute item.removed_at
    refute item.hidden
    assert is_nil(item.removed_at)
    assert {:ok, 0} = Matches.count_queue(scope)
    assert Repo.aggregate(MatchDecision, :count) == 1

    assert {:ok, %{total_count: 0}} = Library.list_source_games(scope)

    assert {:ok, reopened} = Matches.reopen_source(scope, rejected.id)
    refute reopened.manual_lock
    assert reopened.catalog_kind == "unknown"
    assert {:ok, %{total_count: 1}} = Library.list_source_games(scope)
    assert Repo.aggregate(MatchDecision, :count) == 2
  end

  test "an administrator can match a source by an exact IGDB ID" do
    scope = admin_user_fixture() |> Scope.for_user()
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 101, "name" => "Call of Duty®"}])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "101")

    assert {:ok, matched} =
             Matches.apply_igdb_id(scope, source.id, "90001",
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    assert matched.manual_lock
    assert matched.match_method == "manual_id"
    assert Repo.get!(Game, matched.game_id).igdb_id == 90_001
  end

  test "an administrator can search VNDB by title and apply the selected result" do
    scope = admin_user_fixture() |> Scope.for_user()
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 105, "name" => "Unlisted Novel"}])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "105")

    payload = %{
      "id" => "v105",
      "title" => "Unlisted Adult Novel",
      "released" => "2022-03-01",
      "description" => "A VNDB result with useful context.",
      "rating" => 76,
      "votecount" => 42,
      "developers" => [%{"id" => "p105", "name" => "Fixture Circle"}],
      "tags" => [],
      "titles" => [],
      "screenshots" => []
    }

    assert {:ok, [^payload]} =
             Matches.search_vndb_candidates(scope, source.id, "adult (TM) novel®",
               client: VNDBClientStub,
               client_options: [search_results: [payload], test_pid: self()]
             )

    assert_received {:vndb_search, "adult novel"}

    assert {:ok, matched} =
             Matches.apply_vndb_id(scope, source.id, "v105",
               client: VNDBClientStub,
               client_options: [games: [payload]],
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    assert matched.manual_lock
    assert matched.match_method == "manual_vndb"
    assert Repo.get!(Game, matched.game_id).vndb_id == "v105"
  end

  test "classified non-games do not enter the review queue" do
    scope = admin_user_fixture() |> Scope.for_user()
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [
               %{"appid" => 102, "name" => "A Movie"},
               %{"appid" => 103, "name" => "Shooter Playtest"}
             ])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "102")
    source |> GameSource.changeset(%{catalog_kind: "video"}) |> Repo.update!()

    assert Repo.get_by!(GameSource, provider: :steam, external_id: "103").catalog_kind ==
             "playtest"

    assert {:ok, []} = Matches.list_queue(scope)
    assert {:ok, 0} = Matches.count_queue(scope)
  end

  test "an administrator can reopen an automatic match and focus it in the queue" do
    scope = admin_user_fixture() |> Scope.for_user()
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [
               %{"appid" => 201, "name" => "A First Queue Entry"},
               %{"appid" => 202, "name" => "Dungeon Siege Collection"}
             ])

    game =
      %Game{}
      |> Game.changeset(%{
        title: "Dungeon Siege Collection",
        normalized_title: "dungeon siege collection",
        slug: "dungeon-siege-collection-202000",
        igdb_id: 202_000
      })
      |> Repo.insert!()

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "202")

    source
    |> GameSource.changeset(%{
      game_id: game.id,
      match_method: "auto_external_id",
      manual_lock: false
    })
    |> Repo.update!()

    assert {:ok, reopened} = Matches.open_source_for_review(scope, source.id)
    refute reopened.game_id
    refute reopened.manual_lock

    assert {:ok, [focused | _rest]} =
             Matches.list_queue(scope, focus_source_id: source.id)

    assert focused.id == source.id
  end

  test "console and uploaded-library sources enter the review queue" do
    scope = admin_user_fixture() |> Scope.for_user()

    attrs = %{
      external_user_id: "psn-player",
      display_name: "PSN player"
    }

    entry = %{
      external_id: "225857",
      title: "SHADOW OF THE COLOSSUS™",
      relationship: :played,
      metadata: %{}
    }

    assert {:ok, _result} =
             LibraryReconciler.import(scope, :psn, attrs, [entry], complete: false)

    source = Repo.get_by!(GameSource, provider: :psn, external_id: "225857")

    assert {:ok, queued} = Matches.list_queue(scope)
    assert Enum.any?(queued, &(&1.id == source.id))
    assert {:ok, 1} = Matches.count_queue(scope)
  end

  test "reopen_game_for_review reopens every owned source, including custom games" do
    admin = admin_user_fixture()
    scope = Scope.for_user(admin)

    # A custom (IGDB) game added by the admin.
    assert {:ok, %{added: 1}} = Iri.Integrations.Custom.add_ids(scope, [10])
    game = Repo.get_by!(Game, igdb_id: 10)

    source = Repo.get_by!(GameSource, provider: :igdb, external_id: "10")
    assert source.manual_lock
    assert source.game_id == game.id

    assert {:ok, focus_id} = Matches.reopen_game_for_review(scope, game.id)
    assert focus_id == source.id

    reopened = Repo.get!(GameSource, source.id)
    refute reopened.manual_lock
    refute reopened.game_id

    # The custom source now surfaces on the review page when focused, even
    # though its provider is outside the automatic review set.
    assert {:ok, [focused | _]} = Matches.list_queue(scope, focus_source_id: source.id)
    assert focused.id == source.id
  end

  test "reopen_game_for_review is admin-only" do
    viewer = viewer_user_fixture() |> Scope.for_user()
    assert {:error, :unauthorized} = Matches.reopen_game_for_review(viewer, 1)
  end

  defp steam_account_fixture do
    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: :steam,
      external_user_id: "76561198000000001",
      display_name: "Owner"
    })
    |> Repo.insert!()
  end
end
