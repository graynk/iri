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

defmodule Iri.Library.PersonalizationTest do
  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Accounts.Scope
  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{Game, GameSource, LibraryItem, Personalization, UserGameState}

  test "personal fields coexist and clearing one field preserves the others" do
    user = viewer_user_fixture()
    game = accessible_game_fixture(user)
    scope = Scope.for_user(user)

    assert {:ok, preferences} =
             Personalization.set_completion_state(scope, game.id, "completed")

    assert preferences.state == "completed"

    assert {:ok, preferences} = Personalization.set_note(scope, game.id, "  Worth replaying.  ")
    assert preferences.notes == "Worth replaying."
    assert preferences.state == "completed"

    assert {:ok, preferences} = Personalization.set_rating(scope, game.id, 5)
    assert preferences.rating == 5
    assert preferences.notes == "Worth replaying."
    assert preferences.state == "completed"

    assert {:ok, preferences} = Personalization.set_completion_state(scope, game.id, nil)
    assert preferences.state == nil
    assert preferences.rating == 5
    assert preferences.notes == "Worth replaying."

    assert {:ok, preferences} = Personalization.set_rating(scope, game.id, nil)
    assert preferences.rating == nil
    assert preferences.notes == "Worth replaying."

    assert {:ok, nil} = Personalization.set_note(scope, game.id, "  ")
    refute Repo.get_by(UserGameState, user_id: user.id, game_id: game.id)
  end

  test "empty clears do not create rows" do
    user = viewer_user_fixture()
    game = accessible_game_fixture(user)
    scope = Scope.for_user(user)

    assert {:ok, nil} = Personalization.set_completion_state(scope, game.id, nil)
    assert {:ok, nil} = Personalization.set_rating(scope, game.id, nil)
    assert {:ok, nil} = Personalization.set_note(scope, game.id, nil)
    refute Repo.get_by(UserGameState, user_id: user.id, game_id: game.id)
  end

  test "rating and note validation return safe errors" do
    user = viewer_user_fixture()
    game = accessible_game_fixture(user)
    scope = Scope.for_user(user)

    assert {:error, :invalid_rating} = Personalization.set_rating(scope, game.id, 0)
    assert {:error, :invalid_rating} = Personalization.set_rating(scope, game.id, 6)
    assert {:error, :invalid_rating} = Personalization.set_rating(scope, game.id, 3.25)
    assert {:error, :invalid_rating} = Personalization.set_rating(scope, game.id, "5")

    assert {:ok, preferences} = Personalization.set_rating(scope, game.id, 3.5)
    assert preferences.rating == 3.5

    assert {:error, changeset} =
             Personalization.set_note(scope, game.id, String.duplicate("x", 10_001))

    assert "should be at most 10000 character(s)" in errors_on(changeset).notes
  end

  test "preferences cannot be read or changed without current game access" do
    owner = viewer_user_fixture()
    excluded_user = viewer_user_fixture()
    game = accessible_game_fixture(owner)
    excluded_scope = Scope.for_user(excluded_user)

    assert {:error, :not_found} = Personalization.get(excluded_scope, game.id)
    assert {:error, :not_found} = Personalization.set_rating(excluded_scope, game.id, 4)
    assert {:error, :not_found} = Personalization.set_note(excluded_scope, game.id, "No access")
  end

  test "batch completion updates are atomic and preserve other personal fields" do
    user = viewer_user_fixture()
    other_user = viewer_user_fixture()
    first = accessible_game_fixture(user)
    second = accessible_game_fixture(user)
    inaccessible = accessible_game_fixture(other_user)
    scope = Scope.for_user(user)

    assert {:ok, _preferences} = Personalization.set_rating(scope, first.id, 4)
    assert {:ok, _preferences} = Personalization.set_note(scope, first.id, "Keep this")

    assert {:ok, 2} =
             Personalization.batch_set_completion_state(
               scope,
               [Integer.to_string(first.id), second.id, second.id],
               "completed"
             )

    first_preferences = Repo.get_by!(UserGameState, user_id: user.id, game_id: first.id)
    second_preferences = Repo.get_by!(UserGameState, user_id: user.id, game_id: second.id)
    assert first_preferences.state == "completed"
    assert first_preferences.rating == 4
    assert first_preferences.notes == "Keep this"
    assert second_preferences.state == "completed"

    assert {:ok, 2} =
             Personalization.batch_set_completion_state(scope, [first.id, second.id], nil)

    first_preferences = Repo.get_by!(UserGameState, user_id: user.id, game_id: first.id)
    assert first_preferences.state == nil
    assert first_preferences.rating == 4
    assert first_preferences.notes == "Keep this"
    refute Repo.get_by(UserGameState, user_id: user.id, game_id: second.id)

    assert {:ok, 1} =
             Personalization.batch_set_completion_state(scope, [first.id], "completed")

    assert {:error, :not_found} =
             Personalization.batch_set_completion_state(
               scope,
               [first.id, inaccessible.id],
               "dropped"
             )

    assert Repo.get_by!(UserGameState, user_id: user.id, game_id: first.id).state == "completed"

    assert {:ok, 1} =
             Personalization.batch_set_completion_state(scope, [first.id], "playing")

    assert Repo.get_by!(UserGameState, user_id: user.id, game_id: first.id).state == "playing"

    assert {:ok, 1} =
             Personalization.batch_set_completion_state(scope, [first.id], "backlog")

    assert Repo.get_by!(UserGameState, user_id: user.id, game_id: first.id).state == "backlog"

    assert {:error, :invalid_state} =
             Personalization.batch_set_completion_state(scope, [first.id], "wishlist")
  end

  defp accessible_game_fixture(owner) do
    unique = System.unique_integer([:positive])

    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "personalization-#{unique}",
        display_name: "Private library",
        sharing_policy: :selected_users
      })
      |> Ecto.Changeset.put_change(:owner_user_id, owner.id)
      |> Repo.insert!()

    game =
      %Game{}
      |> Game.changeset(%{
        title: "Personal game #{unique}",
        normalized_title: "personal game #{unique}",
        slug: "personal-game-#{unique}"
      })
      |> Repo.insert!()

    source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: :steam,
        external_id: "personal-game-#{unique}",
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

    game
  end
end
