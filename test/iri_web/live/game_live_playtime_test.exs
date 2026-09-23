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
  alias Iri.Library.{Game, GameSource, LibraryItem}
  alias Iri.Repo

  test "shows personal playtime before the IGDB time-to-beat range", %{conn: conn} do
    user = viewer_user_fixture()

    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "playtime-live-user",
        display_name: "Personal Steam"
      })
      |> Ecto.Changeset.put_change(:owner_user_id, user.id)
      |> Repo.insert!()

    game = game_fixture(account, 860)
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game.slug}")

    assert has_element?(view, "#game-playtime")
    assert has_element?(view, "#my-playtime", "Playtime")
    assert has_element?(view, "#my-playtime", "14.3 hours")
    assert has_element?(view, "#game-time-to-beat", "Time to beat")
    assert has_element?(view, "#game-time-to-beat", "5-13 hours")
    assert has_element?(view, "#my-playtime + #game-time-to-beat")
    assert has_element?(view, "#my-playtime .text-sm")
    assert has_element?(view, "#game-time-to-beat .text-sm")
    refute has_element?(view, "#game-time-to-beat", "HLTB")
    refute has_element?(view, "#game-playtime", "Main story to main + extras")
  end

  test "a Steam game's playtime stays read-only", %{conn: conn} do
    user = viewer_user_fixture()
    account = account_fixture(user, :steam, "steam-readonly")
    game = game_fixture(account, 860)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game.slug}")

    assert has_element?(view, "#my-playtime", "14.3 hours")
    refute has_element?(view, "#personal-playtime")
  end

  test "a PSN game's playtime can be typed in and is saved", %{conn: conn} do
    user = viewer_user_fixture()
    account = account_fixture(user, :psn, "psn-editable")
    game = game_fixture(account, 0)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game.slug}")

    assert has_element?(view, "#game-playtime")
    assert has_element?(view, "#personal-playtime")
    refute has_element?(view, "#my-playtime")

    html =
      view
      |> form("#personal-playtime", playtime: %{hours: "12.5"})
      |> render_submit()

    assert Repo.one!(LibraryItem).playtime_minutes == 750
    assert html =~ "12.5"
    assert has_element?(view, "#playtime-feedback", "Playtime saved.")
  end

  test "a number input change saves editable playtime immediately", %{conn: conn} do
    user = viewer_user_fixture()
    account = account_fixture(user, :psn, "psn-change-event")
    game = game_fixture(account, 0)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game.slug}")

    assert has_element?(view, "#personal-playtime[phx-change='save_playtime']")
    assert has_element?(view, "#personal-playtime-input[inputmode='decimal'][type='number']")

    view
    |> form("#personal-playtime", playtime: %{hours: "1.5"})
    |> render_change()

    assert Repo.one!(LibraryItem).playtime_minutes == 90
    assert has_element?(view, "#personal-playtime-input[value='1.5']")
    assert has_element?(view, "#playtime-feedback", "Playtime saved.")
  end

  test "a mixed-store game falls back to reported playtime until manual playtime is saved", %{
    conn: conn
  } do
    user = viewer_user_fixture()
    steam = account_fixture(user, :steam, "steam-mixed")
    psn = account_fixture(user, :psn, "psn-mixed")
    game = game_fixture(steam, 600)
    psn_item = item_fixture(psn, game, 0)
    steam_item = Repo.get_by!(LibraryItem, provider_account_id: steam.id)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game.slug}")

    assert has_element?(view, "#personal-playtime-input[value='10']")

    view
    |> form("#personal-playtime", playtime: %{hours: "5"})
    |> render_submit()

    assert Repo.get!(LibraryItem, steam_item.id).playtime_minutes == 600
    assert Repo.get!(LibraryItem, psn_item.id).playtime_minutes == 300
    assert has_element?(view, "#personal-playtime-input[value='5']")
    assert has_element?(view, "#playtime-feedback", "Playtime saved.")
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

  defp game_fixture(account, playtime_minutes) do
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

    item_fixture(account, game, playtime_minutes)

    game
  end

  defp item_fixture(account, game, playtime_minutes) do
    source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: account.provider,
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
