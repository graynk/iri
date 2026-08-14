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

  defp game_fixture(account, playtime_minutes) do
    game =
      %Game{}
      |> Game.changeset(%{
        igdb_id: 123_456,
        title: "Playtime Game",
        normalized_title: "playtime game",
        slug: "playtime-game-123456",
        time_to_beat_main_seconds: 18_000,
        time_to_beat_extra_seconds: 46_800
      })
      |> Repo.insert!()

    source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: :steam,
        external_id: "playtime-live-game",
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

    game
  end
end
