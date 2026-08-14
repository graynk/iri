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

defmodule Iri.CollectionsTest do
  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Accounts.Scope
  alias Iri.Collections
  alias Iri.Collections.CollectionGame
  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{Game, GameSource, LibraryItem, Personalization}

  test "collections are private, case-insensitively named, and scoped to their owner" do
    owner = viewer_user_fixture()
    other = viewer_user_fixture()
    owner_scope = Scope.for_user(owner)

    assert {:ok, collection} =
             Collections.create_collection(owner_scope, %{name: " Favorite RPGs "})

    assert collection.name == "Favorite RPGs"
    assert [%{collection: listed}] = Collections.list_collections(owner_scope)
    assert listed.id == collection.id
    assert Collections.list_collections(Scope.for_user(other)) == []
    assert {:error, :not_found} = Collections.get_collection(Scope.for_user(other), collection.id)

    assert {:error, changeset} =
             Collections.create_collection(owner_scope, %{name: "favorite rpgs"})

    assert "has already been taken" in errors_on(changeset).name
  end

  test "Family mode lists other users' public collections but never private collections" do
    previous_mode = Application.get_env(:iri, :mode)
    Application.put_env(:iri, :mode, :family)
    on_exit(fn -> Application.put_env(:iri, :mode, previous_mode) end)

    viewer = viewer_user_fixture()
    owner = viewer_user_fixture()
    viewer_scope = Scope.for_user(viewer)
    owner_scope = Scope.for_user(owner)
    game = game_fixture(provider_account_fixture(owner), "Family recommendation")

    {:ok, public_collection} =
      Collections.create_collection(owner_scope, %{name: "Family favorites"})

    {:ok, private_collection} =
      Collections.create_collection(owner_scope, %{name: "Private notes"})

    {:ok, own_public_collection} =
      Collections.create_collection(viewer_scope, %{name: "My public list"})

    assert {:ok, 1} = Collections.add_games(owner_scope, public_collection.id, [game.id])
    assert {:ok, _collection} = Collections.enable_sharing(owner_scope, public_collection.id)
    assert {:ok, _collection} = Collections.enable_sharing(viewer_scope, own_public_collection.id)

    assert [
             %{
               collection: listed,
               owner_name: owner_name,
               accessible_game_count: 1,
               share_token: share_token
             }
           ] = Collections.list_family_public_collections(viewer_scope)

    assert listed.id == public_collection.id
    assert owner_name == owner.username

    assert {:ok, shared} = Collections.get_shared_collection(viewer_scope, share_token)
    assert shared.collection.id == public_collection.id
    assert Enum.map(shared.entries, & &1.title) == ["Family recommendation"]

    refute listed.id == private_collection.id
    refute listed.id == own_public_collection.id

    Application.put_env(:iri, :mode, :public)
    assert Collections.list_family_public_collections(viewer_scope) == []
  end

  test "add is atomic and idempotent, appends by title, and remove normalizes positions" do
    owner = viewer_user_fixture()
    outsider = viewer_user_fixture()
    scope = Scope.for_user(owner)
    account = provider_account_fixture(owner)
    beta = game_fixture(account, "Beta")
    alpha = game_fixture(account, "Alpha")
    inaccessible = game_fixture(provider_account_fixture(outsider), "Secret")
    {:ok, collection} = Collections.create_collection(scope, %{name: "Games"})

    assert {:error, :not_found} =
             Collections.add_games(scope, collection.id, [beta.id, inaccessible.id])

    assert {:error, :invalid_id} = Collections.add_games(scope, collection.id, [beta.id, "bad"])

    assert Repo.aggregate(CollectionGame, :count) == 0
    assert {:ok, 2} = Collections.add_games(scope, collection.id, [beta.id, alpha.id, beta.id])
    assert {:ok, 0} = Collections.add_games(scope, collection.id, [alpha.id, beta.id])

    assert {:ok, _collection, entries} =
             Collections.list_collection_games(scope, collection.id)

    assert Enum.map(entries, &{&1.title, &1.position}) == [{"Alpha", 0}, {"Beta", 1}]

    assert {:ok, :ok} = Collections.remove_game(scope, collection.id, alpha.id)

    assert {:ok, _collection, [remaining]} =
             Collections.list_collection_games(scope, collection.id)

    assert {remaining.title, remaining.position} == {"Beta", 0}
  end

  test "search is access-scoped, includes provider titles, and marks existing entries" do
    owner = viewer_user_fixture()
    other = viewer_user_fixture()
    scope = Scope.for_user(owner)
    account = provider_account_fixture(owner)
    game = game_fixture(account, "Canonical title", "Store alias")
    _hidden = game_fixture(provider_account_fixture(other), "Store alias private")
    {:ok, collection} = Collections.create_collection(scope, %{name: "Search"})

    assert {:ok, [%{id: game_id, added: false}]} =
             Collections.search_addable_games(scope, collection.id, "store alias")

    assert game_id == game.id
    assert {:ok, 1} = Collections.add_games(scope, collection.id, [game.id])

    assert {:ok, [%{id: ^game_id, added: true}]} =
             Collections.search_addable_games(scope, collection.id, "store alias")
  end

  test "game-page memberships update several owned collections atomically" do
    owner = viewer_user_fixture()
    other = viewer_user_fixture()
    scope = Scope.for_user(owner)
    game = game_fixture(provider_account_fixture(owner), "Membership game")

    {:ok, favorites} = Collections.create_collection(scope, %{name: "Favorites"})
    {:ok, backlog} = Collections.create_collection(scope, %{name: "Backlog"})
    {:ok, replay} = Collections.create_collection(scope, %{name: "Replay"})

    {:ok, foreign} =
      Collections.create_collection(Scope.for_user(other), %{name: "Foreign"})

    assert {:ok, 1} = Collections.add_games(scope, favorites.id, [game.id])

    assert {:ok, memberships} = Collections.game_collection_memberships(scope, game.id)

    assert Enum.map(memberships, &{&1.name, &1.member?}) == [
             {"Backlog", false},
             {"Favorites", true},
             {"Replay", false}
           ]

    assert {:ok, %{added: 2, removed: 1}} =
             Collections.set_game_collections(scope, game.id, [backlog.id, replay.id])

    assert {:ok, memberships} = Collections.game_collection_memberships(scope, game.id)

    assert Enum.map(memberships, &{&1.name, &1.member?}) == [
             {"Backlog", true},
             {"Favorites", false},
             {"Replay", true}
           ]

    assert {:error, :not_found} =
             Collections.set_game_collections(scope, game.id, [favorites.id, foreign.id])

    assert {:ok, unchanged} = Collections.game_collection_memberships(scope, game.id)

    assert Enum.filter(unchanged, & &1.member?) |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([backlog.id, replay.id])
  end

  test "reorder operations are scoped, transactional, and preserve dense positions" do
    owner = viewer_user_fixture()
    other = viewer_user_fixture()
    scope = Scope.for_user(owner)
    account = provider_account_fixture(owner)
    alpha = game_fixture(account, "Alpha")
    beta = game_fixture(account, "Beta")
    charlie = game_fixture(account, "Charlie")
    delta = game_fixture(account, "Delta")
    foreign_game = game_fixture(provider_account_fixture(other), "Foreign")
    {:ok, collection} = Collections.create_collection(scope, %{name: "Ordered"})

    assert {:ok, 4} =
             Collections.add_games(scope, collection.id, [delta.id, charlie.id, beta.id, alpha.id])

    assert {:ok, :ok} = Collections.move_game(scope, collection.id, delta.id, beta.id)
    assert collection_order(scope, collection.id) == ["Alpha", "Delta", "Beta", "Charlie"]

    assert {:ok, :ok} = Collections.move_game(scope, collection.id, delta.id, nil)
    assert collection_order(scope, collection.id) == ["Alpha", "Beta", "Charlie", "Delta"]

    assert {:ok, :ok} = Collections.move_game_up(scope, collection.id, charlie.id)
    assert collection_order(scope, collection.id) == ["Alpha", "Charlie", "Beta", "Delta"]

    assert {:ok, :ok} = Collections.move_game_down(scope, collection.id, charlie.id)
    assert collection_order(scope, collection.id) == ["Alpha", "Beta", "Charlie", "Delta"]

    assert {:ok, :ok} = Collections.move_game_up(scope, collection.id, alpha.id)
    assert {:ok, :ok} = Collections.move_game_down(scope, collection.id, delta.id)
    assert {:ok, :ok} = Collections.move_game(scope, collection.id, beta.id, beta.id)
    assert collection_order(scope, collection.id) == ["Alpha", "Beta", "Charlie", "Delta"]

    assert {:error, :not_found} =
             Collections.move_game(scope, collection.id, beta.id, foreign_game.id)

    assert {:error, :not_found} =
             Collections.move_game(Scope.for_user(other), collection.id, beta.id, nil)

    assert {:error, :not_found} =
             Collections.move_game(scope, "not-an-id", beta.id, nil)

    assert {:ok, _collection, entries} = Collections.list_collection_games(scope, collection.id)
    assert Enum.map(entries, & &1.position) == [0, 1, 2, 3]
  end

  test "share capabilities expose a narrow projection and revoke permanently" do
    owner = viewer_user_fixture()
    viewer = viewer_user_fixture()
    owner_scope = Scope.for_user(owner)
    viewer_scope = Scope.for_user(viewer)
    game = game_fixture(provider_account_fixture(owner), "Shared game")
    {:ok, collection} = Collections.create_collection(owner_scope, %{name: "Shared picks"})
    assert {:ok, 1} = Collections.add_games(owner_scope, collection.id, [game.id])

    assert {:ok, _entry} =
             Collections.update_entry_comment(
               owner_scope,
               collection.id,
               game.id,
               "Worth replaying together"
             )

    assert {:ok, _preferences} = Personalization.set_rating(owner_scope, game.id, 5)
    assert {:ok, _preferences} = Personalization.set_note(owner_scope, game.id, "Private note")

    assert {:error, :sharing_disabled} = Collections.share_token(owner_scope, collection.id)
    assert {:ok, _collection} = Collections.enable_sharing(owner_scope, collection.id)
    assert {:ok, old_token} = Collections.share_token(owner_scope, collection.id)

    assert {:ok, shared} = Collections.get_shared_collection(viewer_scope, old_token)
    assert shared.owner_name == owner.username
    assert shared.viewer_is_owner == false

    assert Map.keys(shared.collection) |> Enum.sort() == [:id, :name]

    assert [
             %{
               title: "Shared game",
               personal_rating: 5.0,
               comment: "Worth replaying together"
             } = entry
           ] = shared.entries

    refute Map.has_key?(entry, :notes)
    refute Map.has_key?(entry, :state)
    refute Map.has_key?(entry, :playtime_minutes)
    refute Map.has_key?(entry, :provider_account_id)

    assert {:ok, _collection} = Collections.disable_sharing(owner_scope, collection.id)
    assert {:error, :not_found} = Collections.get_shared_collection(viewer_scope, old_token)
    assert {:ok, _collection} = Collections.enable_sharing(owner_scope, collection.id)
    assert {:ok, new_token} = Collections.share_token(owner_scope, collection.id)
    refute new_token == old_token
    assert {:error, :not_found} = Collections.get_shared_collection(viewer_scope, old_token)
    assert {:ok, _shared} = Collections.get_shared_collection(viewer_scope, new_token)

    assert {:ok, _collection} = Collections.regenerate_share_link(owner_scope, collection.id)
    assert {:error, :not_found} = Collections.get_shared_collection(viewer_scope, new_token)
  end

  test "collection-entry comments are owner-scoped, trimmed, optional, and limited" do
    owner = viewer_user_fixture()
    other = viewer_user_fixture()
    scope = Scope.for_user(owner)
    game = game_fixture(provider_account_fixture(owner), "Commented game")
    {:ok, collection} = Collections.create_collection(scope, %{name: "Notes"})
    assert {:ok, 1} = Collections.add_games(scope, collection.id, [game.id])

    assert {:ok, entry} =
             Collections.update_entry_comment(scope, collection.id, game.id, "  Short take  ")

    assert entry.comment == "Short take"

    assert {:ok, _collection, [%{comment: "Short take"}]} =
             Collections.list_collection_games(scope, collection.id)

    assert {:error, %Ecto.Changeset{}} =
             Collections.update_entry_comment(
               scope,
               collection.id,
               game.id,
               String.duplicate("x", 301)
             )

    assert {:error, :not_found} =
             Collections.update_entry_comment(
               Scope.for_user(other),
               collection.id,
               game.id,
               "No access"
             )

    assert {:ok, cleared} = Collections.update_entry_comment(scope, collection.id, game.id, "  ")
    assert cleared.comment == nil
  end

  test "collection sorts are deterministic, temporary, and default to manual order" do
    owner = viewer_user_fixture()
    viewer = viewer_user_fixture()
    owner_scope = Scope.for_user(owner)
    account = provider_account_fixture(owner)
    alpha = game_fixture(account, "Alpha", nil, 40.0)
    beta = game_fixture(account, "Beta", nil, 90.0)
    gamma = game_fixture(account, "Gamma", nil, nil)
    alpha |> Ecto.Changeset.change(release_year: 2010) |> Repo.update!()
    beta |> Ecto.Changeset.change(release_year: 2020) |> Repo.update!()
    gamma |> Ecto.Changeset.change(release_year: nil) |> Repo.update!()
    {:ok, collection} = Collections.create_collection(owner_scope, %{name: "Sorted"})

    assert {:ok, 1} = Collections.add_games(owner_scope, collection.id, [gamma.id])
    assert {:ok, 1} = Collections.add_games(owner_scope, collection.id, [alpha.id])
    assert {:ok, 1} = Collections.add_games(owner_scope, collection.id, [beta.id])
    assert {:ok, _state} = Personalization.set_rating(owner_scope, alpha.id, 5)
    assert {:ok, _state} = Personalization.set_rating(owner_scope, beta.id, 1)

    assert {:ok, _collection, custom, "custom", "asc"} =
             Collections.list_collection_games(owner_scope, collection.id, "custom", "asc")

    assert Enum.map(custom, & &1.title) == ["Gamma", "Alpha", "Beta"]

    assert {:ok, _collection, by_title_desc, "title", "desc"} =
             Collections.list_collection_games(owner_scope, collection.id, "title", "desc")

    assert Enum.map(by_title_desc, & &1.title) == ["Gamma", "Beta", "Alpha"]

    assert {:ok, _collection, by_title_asc, "title", "asc"} =
             Collections.list_collection_games(owner_scope, collection.id, "title", "asc")

    assert Enum.map(by_title_asc, & &1.title) == ["Alpha", "Beta", "Gamma"]

    assert {:ok, _collection, by_year_desc, "release_year", "desc"} =
             Collections.list_collection_games(owner_scope, collection.id, "release_year", "desc")

    assert Enum.map(by_year_desc, & &1.title) == ["Beta", "Alpha", "Gamma"]

    assert {:ok, _collection, by_year_asc, "release_year", "asc"} =
             Collections.list_collection_games(owner_scope, collection.id, "release_year", "asc")

    assert Enum.map(by_year_asc, & &1.title) == ["Alpha", "Beta", "Gamma"]

    assert {:ok, _collection, by_igdb, "igdb_rating", "desc"} =
             Collections.list_collection_games(owner_scope, collection.id, "igdb_rating", "desc")

    assert Enum.map(by_igdb, & &1.title) == ["Beta", "Alpha", "Gamma"]

    assert {:ok, _collection, by_personal, "my_rating", "desc"} =
             Collections.list_collection_games(owner_scope, collection.id, "my_rating", "desc")

    assert Enum.map(by_personal, & &1.title) == ["Alpha", "Beta", "Gamma"]

    assert {:ok, _collection} = Collections.enable_sharing(owner_scope, collection.id)
    assert {:ok, token} = Collections.share_token(owner_scope, collection.id)

    assert {:ok, shared_default} =
             Collections.get_shared_collection(Scope.for_user(viewer), token)

    assert shared_default.sort == "custom"
    assert shared_default.sort_direction == "asc"
    assert Enum.map(shared_default.entries, & &1.title) == ["Gamma", "Alpha", "Beta"]

    assert {:ok, shared_title} =
             Collections.get_shared_collection(Scope.for_user(viewer), token, "title", "asc")

    assert Enum.map(shared_title.entries, & &1.title) == ["Alpha", "Beta", "Gamma"]

    assert {:ok, shared_default_again} =
             Collections.get_shared_collection(Scope.for_user(viewer), token)

    assert shared_default_again.sort == "custom"
    assert Enum.map(shared_default_again.entries, & &1.title) == ["Gamma", "Alpha", "Beta"]
  end

  test "a 500-entry collection is returned in bounded deterministic pages" do
    owner = viewer_user_fixture()
    scope = Scope.for_user(owner)
    account = provider_account_fixture(owner)

    games =
      Enum.map(1..500, fn number ->
        game_fixture(
          account,
          "Scale game #{String.pad_leading(Integer.to_string(number), 3, "0")}"
        )
      end)

    {:ok, collection} = Collections.create_collection(scope, %{name: "Scale test"})
    assert {:ok, 500} = Collections.add_games(scope, collection.id, Enum.map(games, & &1.id))

    {entries, cursors} = collect_collection_pages(scope, collection.id, nil, [], [])

    assert length(entries) == 500
    assert Enum.uniq_by(entries, & &1.game_id) == entries
    assert Enum.map(entries, & &1.position) == Enum.to_list(0..499)
    assert cursors == [100, 200, 300, 400, nil]
  end

  defp provider_account_fixture(owner) do
    unique = System.unique_integer([:positive])

    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: :steam,
      external_user_id: "collection-account-#{unique}",
      display_name: "Collection account",
      sharing_policy: :selected_users
    })
    |> Ecto.Changeset.put_change(:owner_user_id, owner.id)
    |> Repo.insert!()
  end

  defp collection_order(scope, collection_id) do
    {:ok, _collection, entries} = Collections.list_collection_games(scope, collection_id)
    Enum.map(entries, & &1.title)
  end

  defp collect_collection_pages(scope, collection_id, cursor, entries, cursors) do
    assert {:ok, page} =
             Collections.list_collection_games_page(
               scope,
               collection_id,
               "custom",
               "asc",
               cursor
             )

    entries = entries ++ page.entries
    cursors = cursors ++ [page.next_cursor]

    if page.next_cursor do
      collect_collection_pages(scope, collection_id, page.next_cursor, entries, cursors)
    else
      {entries, cursors}
    end
  end

  defp game_fixture(account, title, source_title \\ nil, rating \\ 85.0) do
    unique = System.unique_integer([:positive])
    normalized_title = Iri.Library.Title.normalize(title)
    source_title = source_title || title

    game =
      %Game{}
      |> Game.changeset(%{
        title: title,
        normalized_title: normalized_title,
        slug: "collection-game-#{unique}",
        release_year: 2020,
        rating: rating
      })
      |> Repo.insert!()

    source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: :steam,
        external_id: "collection-game-#{unique}",
        source_title: source_title,
        normalized_source_title: Iri.Library.Title.normalize(source_title),
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

    game
  end
end
