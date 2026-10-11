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

defmodule Iri.Integrations.CustomTest do
  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Accounts.Scope
  alias Iri.Collections
  alias Iri.Integrations.{Custom, ProviderAccount}
  alias Iri.Library.{Game, GameSource, LibraryItem, Personalization, UserGameState}

  test "parses batches and adds canonical IGDB games to a user's manual library" do
    scope = viewer_user_fixture() |> Scope.for_user()
    assert {:ok, [10, 20]} = Custom.parse_ids("10, https://www.igdb.com/games/example/20 10")
    assert {:ok, %{added: 2}} = Custom.add_ids(scope, [10, 20])
    assert Repo.aggregate(LibraryItem, :count) == 2
    assert Repo.get_by!(GameSource, provider: :igdb, external_id: "10").manual_lock
  end

  test "a newly added custom game starts at zero hours and reports the added game" do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)

    assert {:ok, %{added: 1, added_games: [game]}} = Custom.add_id(scope, 10)
    assert Repo.one!(LibraryItem).playtime_minutes == 0

    # Typed-in hours are the viewer's personal offset, set by the caller.
    assert {:ok, _state} = Personalization.set_playtime_offset(scope, game.id, 210)

    assert Repo.get_by!(UserGameState, user_id: user.id, game_id: game.id).playtime_offset_minutes ==
             210
  end

  test "a batch add without hours leaves playtime at zero" do
    scope = viewer_user_fixture() |> Scope.for_user()

    assert {:ok, %{added: 2}} = Custom.add_ids(scope, [10, 20])
    assert Enum.all?(Repo.all(LibraryItem), &(&1.playtime_minutes == 0))
  end

  test "caches the IGDB cover while adding a manual game" do
    scope = viewer_user_fixture() |> Scope.for_user()
    test_pid = self()

    assert {:ok, %{added: 1}} =
             Custom.add_ids(scope, [10],
               cache_cover: fn game_id, _options ->
                 send(test_pid, {:cover_cached, game_id})
                 {:ok, :cached}
               end
             )

    game_id = Repo.get_by!(Game, igdb_id: 10).id
    assert_received {:cover_cached, ^game_id}
  end

  test "reports ownership, refuses duplicates, and removes custom games cleanly" do
    scope = viewer_user_fixture() |> Scope.for_user()

    assert {:ok, %{added: 1, already_owned: 0}} = Custom.add_ids(scope, [10])
    assert {:ok, %{added: 0, already_owned: 1}} = Custom.add_ids(scope, [10])
    assert Repo.aggregate(LibraryItem, :count) == 1

    assert {:ok, statuses} = Custom.ownership_status(scope, [10])
    assert statuses[10] == %{owned: true, custom_owned: true}

    assert {:ok, %{removed: 1}} = Custom.remove_igdb_id(scope, 10)
    assert Repo.aggregate(LibraryItem, :count) == 0
    refute Repo.get_by(GameSource, provider: :igdb, external_id: "10")

    assert {:ok, statuses} = Custom.ownership_status(scope, [10])
    refute Map.has_key?(statuses, 10)
  end

  test "refuses to add a game the user already owns through another store" do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)

    assert {:ok, %{added: 1}} = Custom.add_ids(scope, [10])
    game = Repo.get_by!(Game, igdb_id: 10)
    assert {:ok, %{removed: 1}} = Custom.remove_igdb_id(scope, 10)

    steam_account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "76561197960287930",
        display_name: "Steam owner"
      })
      |> Ecto.Changeset.put_change(:owner_user_id, user.id)
      |> Repo.insert!()

    steam_source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: :steam,
        external_id: "620",
        source_title: "Canonical Game 10",
        game_id: game.id
      })
      |> Repo.insert!()

    %LibraryItem{}
    |> LibraryItem.changeset(%{
      provider_account_id: steam_account.id,
      game_source_id: steam_source.id,
      relationship: :owned
    })
    |> Repo.insert!()

    assert {:ok, %{added: 0, already_owned: 1}} = Custom.add_ids(scope, [10])
    refute Repo.get_by(GameSource, provider: :igdb, external_id: "10")

    assert {:ok, statuses} = Custom.ownership_status(scope, [10])
    assert statuses[10] == %{owned: true, custom_owned: false}
  end

  test "replaces one user's custom selection and carries offset, state, and organization forward" do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)

    assert {:ok, %{added: 1, added_games: [old_game]}} = Custom.add_id(scope, 10)
    assert {:ok, _state} = Personalization.set_playtime_offset(scope, old_game.id, 210)
    assert {:ok, _state} = Personalization.set_completion_state(scope, old_game.id, "playing")
    assert {:ok, collection} = Collections.create_collection(scope, %{name: "Favorites"})
    assert {:ok, 1} = Collections.add_games(scope, collection.id, [old_game.id])

    assert {:ok, %{game: target_game}} =
             Custom.replace_game(scope, old_game.id, 20,
               cache_cover: fn _game_id, _options -> {:ok, :cached} end
             )

    assert target_game.igdb_id == 20
    refute Repo.get_by(GameSource, provider: :igdb, external_id: "10")
    assert Repo.get_by!(GameSource, provider: :igdb, external_id: "20").game_id == target_game.id

    # Items start and stay at zero; the typed hours ride along as the offset.
    assert Enum.all?(Repo.all(LibraryItem), &(&1.playtime_minutes == 0))

    target_state = Repo.get_by!(UserGameState, user_id: user.id, game_id: target_game.id)
    assert target_state.state == "playing"
    assert target_state.playtime_offset_minutes == 210

    refute Repo.get_by(UserGameState, user_id: user.id, game_id: old_game.id)

    assert {:ok, _collection, entries} = Collections.list_collection_games(scope, collection.id)
    assert Enum.map(entries, & &1.game_id) == [target_game.id]
  end

  test "fixing the match moves the offset and collection forward while the old game stays accessible" do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)
    stranger = viewer_user_fixture()

    assert {:ok, %{added: 1, added_games: [old_game]}} = Custom.add_id(scope, 10)
    assert {:ok, _state} = Personalization.set_playtime_offset(scope, old_game.id, 210)
    assert {:ok, _state} = Personalization.set_rating(scope, old_game.id, 4.5)
    assert {:ok, collection} = Collections.create_collection(scope, %{name: "Favorites"})
    assert {:ok, 1} = Collections.add_games(scope, collection.id, [old_game.id])

    # The old game stays visible to the user through a shared library of
    # someone else (e.g. a family member owns the same game).
    stranger_account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "76561197999999999",
        display_name: "Family Steam",
        sharing_policy: :everyone
      })
      |> Ecto.Changeset.put_change(:owner_user_id, stranger.id)
      |> Repo.insert!()

    stranger_source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: :steam,
        external_id: "family-620",
        source_title: "Canonical Game 10",
        game_id: old_game.id
      })
      |> Repo.insert!()

    %LibraryItem{}
    |> LibraryItem.changeset(%{
      provider_account_id: stranger_account.id,
      game_source_id: stranger_source.id,
      relationship: :owned
    })
    |> Repo.insert!()

    assert {:ok, %{game: target_game}} =
             Custom.replace_game(scope, old_game.id, 20,
               cache_cover: fn _game_id, _options -> {:ok, :cached} end
             )

    # The offset and the organization follow the fixed custom game even
    # though the old game is still visible ...
    assert Repo.get_by!(UserGameState, user_id: user.id, game_id: target_game.id).playtime_offset_minutes ==
             210

    assert {:ok, _collection, entries} = Collections.list_collection_games(scope, collection.id)
    assert Enum.map(entries, & &1.game_id) == [target_game.id]

    # ... while the old game keeps its own personalization, minus the moved offset.
    old_state = Repo.get_by!(UserGameState, user_id: user.id, game_id: old_game.id)
    assert old_state.rating == 4.5
    assert old_state.playtime_offset_minutes == 0
  end

  test "replacing onto an already-owned game merges the offsets instead of losing hours" do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)

    assert {:ok, %{added: 1, added_games: [old_game]}} = Custom.add_id(scope, 10)
    assert {:ok, _} = Personalization.set_playtime_offset(scope, old_game.id, 210)

    assert {:ok, %{added: 1, added_games: [target_game]}} = Custom.add_id(scope, 20)
    assert {:ok, _} = Personalization.set_playtime_offset(scope, target_game.id, 90)

    assert {:ok, %{game: final_game}} =
             Custom.replace_game(scope, old_game.id, 20,
               cache_cover: fn _game_id, _options -> {:ok, :cached} end
             )

    final_state = Repo.get_by!(UserGameState, user_id: user.id, game_id: final_game.id)
    assert final_state.playtime_offset_minutes == 300
    refute Repo.get_by(UserGameState, user_id: user.id, game_id: old_game.id)
  end

  test "replacing onto an already-owned game clamps the merged offset at the storage bound" do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)

    assert {:ok, %{added: 1, added_games: [old_game]}} = Custom.add_id(scope, 10)
    assert {:ok, _state} = Personalization.set_playtime_offset(scope, old_game.id, 6_000_000)

    assert {:ok, %{added: 1, added_games: [target_game]}} = Custom.add_id(scope, 20)
    assert {:ok, _state} = Personalization.set_playtime_offset(scope, target_game.id, 6_000_000)

    assert {:ok, %{game: final_game}} =
             Custom.replace_game(scope, old_game.id, 20,
               cache_cover: fn _game_id, _options -> {:ok, :cached} end
             )

    # 100,000 h + 100,000 h would exceed the signed-wide storage bound; the
    # merge clamps instead of tripping the check constraint mid-transaction.
    assert Repo.get_by!(UserGameState, user_id: user.id, game_id: final_game.id).playtime_offset_minutes ==
             6_000_000

    refute Repo.get_by(UserGameState, user_id: user.id, game_id: old_game.id)
  end
end
