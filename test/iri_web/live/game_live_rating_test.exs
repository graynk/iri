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

defmodule IriWeb.GameLiveRatingTest do
  use IriWeb.ConnCase

  import Iri.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{Game, GameSource, LibraryItem}
  alias Iri.Repo

  setup %{conn: conn} do
    user = viewer_user_fixture()

    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "rating-live-1",
        display_name: "Rating library"
      })
      |> Ecto.Changeset.put_change(:owner_user_id, user.id)
      |> Repo.insert!()

    game = game_fixture(account)
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game.slug}")
    %{view: view}
  end

  test "a whole-number rating renders a full (not half) icon", %{view: view} do
    rating_cells =
      view
      |> form("#personal-rating", rating: %{value: "2"})
      |> render_change()
      |> rating_region()

    # The second face is selected and drawn full: no half-fill overlay.
    assert rating_cells =~ ~s(data-rating-face="2" data-rating-value="2")
    refute rating_cells =~ "opacity-30"
    assert count(rating_cells, "-400/15") == 1
  end

  test "a half rating renders a half-filled icon", %{view: view} do
    rating_cells =
      view
      |> form("#personal-rating", rating: %{value: "1.5"})
      |> render_change()
      |> rating_region()

    assert count(rating_cells, "opacity-30") == 1
  end

  test "clearing the rating leaves no face selected", %{view: view} do
    view |> form("#personal-rating", rating: %{value: "2"}) |> render_change()

    rating_cells =
      view
      |> element("#clear-personal-rating")
      |> render_click()
      |> rating_region()

    # No cell should carry a selected fill after clearing.
    assert count(rating_cells, "-400/15") == 0
  end

  test "each face exposes hover-preview peers for half and full selection", %{view: view} do
    rating_cells =
      view
      |> form("#personal-rating", rating: %{value: "3"})
      |> render_change()
      |> rating_region()

    assert rating_cells =~ "peer/half"
    assert rating_cells =~ "peer-hover/full:block"
    assert count(rating_cells, "bg-teal-300/30") == 10
    refute rating_cells =~ "bg-white/10"
  end

  defp rating_region(html) do
    [_, block] = String.split(html, ~s(id="personal-rating"), parts: 2)
    [inner, _] = String.split(block, "</form>", parts: 2)
    inner
  end

  defp count(haystack, needle), do: haystack |> String.split(needle) |> length() |> Kernel.-(1)

  defp game_fixture(account) do
    game =
      %Game{}
      |> Game.changeset(%{
        title: "Rating Game",
        normalized_title: "rating game",
        slug: "rating-game-1"
      })
      |> Repo.insert!()

    source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: :steam,
        external_id: "rating-live-game-1",
        source_title: "Rating Game",
        normalized_source_title: "rating game",
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
