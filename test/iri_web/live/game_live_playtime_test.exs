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

defmodule IriWeb.GameLivePlaytimeTest do
  use IriWeb.ConnCase

  import Iri.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{Game, GameSource, LibraryItem, UserGameState}
  alias Iri.Repo

  test "the playtime field is always available and the label follows the context", %{
    conn: conn
  } do
    user = viewer_user_fixture()
    account = account_fixture(user, :steam, "steam-context")
    game = game_fixture(account, 858)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game.slug}")

    # Own store hours exist: the field edits the extra hours on top of them.
    assert has_element?(view, "#game-playtime")
    assert has_element?(view, "#personal-playtime")
    assert has_element?(view, "#game-playtime", "Extra hours")

    assert has_element?(
             view,
             "#personal-playtime-input[aria-label='Extra hours added on top of your library playtime']"
           )

    # The total helper line breaks the total down, above the time-to-beat row.
    assert has_element?(view, "#playtime-total", "14.3h total · 14.3h libraries")
    assert has_element?(view, "#playtime-total + #game-time-to-beat")
    assert has_element?(view, "#game-time-to-beat", "5-13 hours")
    refute has_element?(view, "#my-playtime")
  end

  test "without own store hours the label is Playtime and no total line shows", %{
    conn: conn
  } do
    user = viewer_user_fixture()
    account = account_fixture(user, :psn, "psn-context")
    game = game_fixture(account, 0)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game.slug}")

    assert has_element?(view, "#personal-playtime")
    assert has_element?(view, "#game-playtime", "Playtime")
    assert has_element?(view, "#personal-playtime-input[aria-label='Hours played']")
    refute has_element?(view, "#playtime-total")
  end

  test "typing hours saves the personal offset, never the item hours", %{conn: conn} do
    user = viewer_user_fixture()
    account = account_fixture(user, :psn, "psn-editable")
    game = game_fixture(account, 0)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game.slug}")

    html =
      view
      |> form("#personal-playtime", playtime: %{hours: "12.5"})
      |> render_submit()

    assert offset_minutes(user, game) == 750
    assert Repo.one!(LibraryItem).playtime_minutes == 0
    assert html =~ "12.5"
    assert has_element?(view, "#playtime-feedback", "Playtime saved.")
  end

  test "a number input change saves the personal offset immediately", %{conn: conn} do
    user = viewer_user_fixture()
    account = account_fixture(user, :psn, "psn-change-event")
    game = game_fixture(account, 0)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game.slug}")

    assert has_element?(view, "#personal-playtime[phx-change='save_playtime']")
    assert has_element?(view, "#personal-playtime-input[inputmode='decimal'][type='number']")
    assert has_element?(view, "#personal-playtime-input[min='0'][max='100000']")

    view
    |> form("#personal-playtime", playtime: %{hours: "1.5"})
    |> render_change()

    assert offset_minutes(user, game) == 90
    assert Repo.one!(LibraryItem).playtime_minutes == 0
    assert has_element?(view, "#personal-playtime-input[value='1.5']")
    assert has_element?(view, "#playtime-feedback", "Playtime saved.")
  end

  test "out-of-range input is rejected with a bounded-range message", %{conn: conn} do
    user = viewer_user_fixture()
    account = account_fixture(user, :psn, "psn-range")
    game = game_fixture(account, 0)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game.slug}")

    view
    |> form("#personal-playtime", playtime: %{hours: "100001"})
    |> render_submit()

    refute has_element?(view, "#playtime-feedback", "Playtime saved.")
    assert Repo.aggregate(UserGameState, :count) == 0
    assert has_element?(view, "#flash-error", "Enter hours between 0 and 100,000.")
  end

  test "a save failure flashes the generic message instead of the parse hint", %{conn: conn} do
    user = viewer_user_fixture()
    account = account_fixture(user, :psn, "psn-generic")
    game = game_fixture(account, 0)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game.slug}")

    # Dropping access after the page loaded makes the save itself fail, not
    # the parsing of the typed hours.
    account |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

    view
    |> form("#personal-playtime", playtime: %{hours: "5"})
    |> render_submit()

    assert has_element?(view, "#flash-error", "Could not save your playtime.")
    refute has_element?(view, "#flash-error", "Enter hours between 0 and 100,000.")
  end

  test "a shared custom game gets a personal offset without claiming the game", %{conn: conn} do
    owner = viewer_user_fixture()
    viewer = viewer_user_fixture()
    account = account_fixture(owner, :custom, "owner-custom")
    game = game_fixture(account, 120, :igdb)
    owner_item = Repo.one!(LibraryItem)

    {:ok, view, _html} = conn |> log_in_user(viewer) |> live(~p"/games/#{game.slug}")

    # The owner's 2h are not the viewer's store hours, so the label is
    # Playtime for the viewer.
    assert has_element?(view, "#game-playtime", "Playtime")

    view
    |> form("#personal-playtime", playtime: %{hours: "4"})
    |> render_change()

    assert offset_minutes(viewer, game) == 240
    assert offset_minutes(owner, game) == 0
    assert Repo.get!(LibraryItem, owner_item.id).playtime_minutes == 120

    # Typing no longer claims a shared custom game into the viewer's library.
    assert Repo.aggregate(LibraryItem, :count) == 1
    assert has_element?(view, "#personal-playtime-input[value='4']")
    assert has_element?(view, "#playtime-feedback", "Playtime saved.")
  end

  test "store hours sum across stores and the offset adds on top", %{conn: conn} do
    user = viewer_user_fixture()
    steam = account_fixture(user, :steam, "steam-mixed")
    psn = account_fixture(user, :psn, "psn-mixed")
    game = game_fixture(steam, 600)
    psn_item = item_fixture(psn, game, 300)
    steam_item = Repo.get_by!(LibraryItem, provider_account_id: steam.id)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game.slug}")

    # 600 + 300 = 15h of own library hours; the offset starts empty.
    assert has_element?(view, "#playtime-total", "15h total · 15h libraries")

    view
    |> form("#personal-playtime", playtime: %{hours: "5"})
    |> render_submit()

    assert offset_minutes(user, game) == 300
    assert Repo.get!(LibraryItem, steam_item.id).playtime_minutes == 600
    assert Repo.get!(LibraryItem, psn_item.id).playtime_minutes == 300
    assert has_element?(view, "#personal-playtime-input[value='5']")
    assert has_element?(view, "#playtime-total", "20h total · 15h libraries · 5h extra")
    assert has_element?(view, "#playtime-feedback", "Playtime saved.")
  end

  test "a corrupted negative offset can never render a total below zero", %{conn: conn} do
    user = viewer_user_fixture()
    account = account_fixture(user, :steam, "steam-clamp")
    game = game_fixture(account, 120)

    # Bypass the write guards: a negative offset can only exist via the open
    # negative decision, a future write bug, or a corrupted row.
    %UserGameState{user_id: user.id, game_id: game.id, playtime_offset_minutes: -600}
    |> Repo.insert!()

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game.slug}")

    # 120 minutes of store hours minus 600 minutes of offset clamps to 0.
    assert has_element?(view, "#playtime-total", "0h total · 2h libraries")
    refute has_element?(view, "#game-playtime", "extra")
  end

  defp offset_minutes(user, game) do
    case Repo.get_by(UserGameState, user_id: user.id, game_id: game.id) do
      %UserGameState{playtime_offset_minutes: minutes} -> minutes
      nil -> 0
    end
  end

  defp account_fixture(user, provider, external_user_id) do
    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: provider,
      external_user_id: external_user_id,
      display_name: "#{provider} account"
    })
    |> Ecto.Changeset.put_change(:owner_user_id, user.id)
    |> Repo.insert!()
  end

  defp game_fixture(account, playtime_minutes, source_provider \\ nil) do
    game =
      %Game{}
      |> Game.changeset(%{
        igdb_id: System.unique_integer([:positive]),
        title: "Playtime Game",
        normalized_title: "playtime game",
        slug: "playtime-game-#{System.unique_integer([:positive])}",
        time_to_beat_main_seconds: 18_000,
        time_to_beat_extra_seconds: 46_800
      })
      |> Repo.insert!()

    item_fixture(account, game, playtime_minutes, source_provider)

    game
  end

  defp item_fixture(account, game, playtime_minutes, source_provider \\ nil) do
    source_provider = source_provider || account.provider

    source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: source_provider,
        external_id: "playtime-live-game-#{System.unique_integer([:positive])}",
        source_title: game.title,
        normalized_source_title: game.normalized_title,
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
  end
end
