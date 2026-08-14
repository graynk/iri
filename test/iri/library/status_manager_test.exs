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

defmodule Iri.Library.StatusManagerTest do
  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Accounts.Scope
  alias Iri.Integrations.ProviderAccount
  alias Iri.Library
  alias Iri.Library.{Game, GameSource, LibraryItem, StatusManager}

  test "lists only accessible canonical games with search, status, and year sorting" do
    user = viewer_user_fixture()
    excluded_user = viewer_user_fixture()
    scope = Scope.for_user(user)

    alpha = accessible_game_fixture(user, "Alpha", 2020, 60)
    beta = accessible_game_fixture(user, "Beta", 2010, 180)
    playing_game = accessible_game_fixture(user, "Current game", 2022, 120)
    unknown = accessible_game_fixture(user, "Unknown year", nil)
    _excluded = accessible_game_fixture(excluded_user, "Excluded", 2024)

    assert {:ok, page} = StatusManager.list_games(scope)
    assert page.total_count == 4
    assert page.page == 1
    assert page.page_count == 1

    assert Enum.map(page.entries, & &1.title) == [
             "Alpha",
             "Beta",
             "Current game",
             "Unknown year"
           ]

    assert {:ok, without_alpha} =
             StatusManager.list_games(scope, %{}, exclude_ids: [alpha.id])

    assert without_alpha.total_count == 3
    refute Enum.any?(without_alpha.entries, &(&1.id == alpha.id))

    assert {:ok, newest} = StatusManager.list_games(scope, %{"sort" => "release_desc"})
    assert Enum.map(newest.entries, & &1.release_year) == [2022, 2020, 2010, nil]

    assert {:ok, oldest} = StatusManager.list_games(scope, %{"sort" => "release_asc"})
    assert Enum.map(oldest.entries, & &1.release_year) == [2010, 2020, 2022, nil]

    assert {:ok, longest} =
             StatusManager.list_games(scope, %{"sort" => "playtime", "direction" => "desc"})

    assert Enum.map(longest.entries, & &1.title) == [
             "Beta",
             "Current game",
             "Alpha",
             "Unknown year"
           ]

    assert {:ok, shortest} =
             StatusManager.list_games(scope, %{"sort" => "playtime", "direction" => "asc"})

    assert Enum.map(shortest.entries, & &1.title) == [
             "Unknown year",
             "Alpha",
             "Current game",
             "Beta"
           ]

    assert {:ok, searched} = StatusManager.list_games(scope, %{"q" => "beta"})
    assert Enum.map(searched.entries, & &1.id) == [beta.id]

    assert {:ok, _state} = Library.set_game_state(scope, alpha.id, "completed")
    assert {:ok, _state} = Library.set_game_state(scope, beta.id, "dropped")
    assert {:ok, _state} = Library.set_game_state(scope, playing_game.id, "playing")

    assert {:ok, completed} = StatusManager.list_games(scope, %{"status" => "completed"})
    assert Enum.map(completed.entries, & &1.id) == [alpha.id]

    assert {:ok, dropped} = StatusManager.list_games(scope, %{"status" => "dropped"})
    assert Enum.map(dropped.entries, & &1.id) == [beta.id]

    assert {:ok, playing} = StatusManager.list_games(scope, %{"status" => "playing"})
    assert Enum.map(playing.entries, & &1.id) == [playing_game.id]

    assert {:ok, not_played} =
             StatusManager.list_games(scope, %{"status" => "not_played"})

    assert Enum.map(not_played.entries, & &1.id) == [unknown.id]

    assert {:ok, _state} = Library.set_game_state(scope, unknown.id, "backlog")
    assert {:ok, backlog} = StatusManager.list_games(scope, %{"status" => "backlog"})
    assert Enum.map(backlog.entries, & &1.id) == [unknown.id]

    assert {:ok, not_played} =
             StatusManager.list_games(scope, %{"status" => "not_played"})

    assert not_played.entries == []

    assert {:ok, rows} = StatusManager.list_games_by_ids(scope, [alpha.id, unknown.id])
    assert Enum.map(rows, & &1.id) |> Enum.sort() == Enum.sort([alpha.id, unknown.id])
  end

  defp accessible_game_fixture(owner, title, release_year, playtime_minutes \\ 0) do
    unique = System.unique_integer([:positive])
    normalized_title = Iri.Library.Title.normalize(title)

    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :gog,
        external_user_id: "status-manager-#{unique}",
        display_name: "Status library #{unique}",
        sharing_policy: :selected_users
      })
      |> Ecto.Changeset.put_change(:owner_user_id, owner.id)
      |> Repo.insert!()

    game =
      %Game{}
      |> Game.changeset(%{
        title: title,
        normalized_title: normalized_title,
        slug: "status-game-#{unique}",
        release_year: release_year
      })
      |> Repo.insert!()

    source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: :gog,
        external_id: "status-game-#{unique}",
        source_title: title,
        normalized_source_title: normalized_title,
        game_id: game.id,
        catalog_kind: "game"
      })
      |> Repo.insert!()

    %LibraryItem{}
    |> LibraryItem.changeset(%{
      provider_account_id: account.id,
      game_source_id: source.id,
      playtime_minutes: playtime_minutes
    })
    |> Repo.insert!()

    game
  end
end
