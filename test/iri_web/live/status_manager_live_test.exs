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

defmodule IriWeb.StatusManagerLiveTest do
  use IriWeb.ConnCase

  import Ecto.Query
  import Iri.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{Game, GameSource, LibraryItem, UserGameState}
  alias Iri.Repo

  test "anonymous visitors are redirected to login", %{conn: conn} do
    # An instance that already has an account sends anonymous visitors to log
    # in; a fresh instance sends them to registration instead.
    _existing = viewer_user_fixture()

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(conn, ~p"/library/statuses")
  end

  test "selects ranges, applies a status, and clears selection when the query changes", %{
    conn: conn
  } do
    user = viewer_user_fixture()
    account = provider_account_fixture(user)

    user =
      user
      |> Ecto.Changeset.change(steam_id: account.external_user_id)
      |> Repo.update!()

    alpha = game_fixture(account, "Alpha", 2020, 185)
    beta = game_fixture(account, "Beta", 2015)
    gamma = game_fixture(account, "Gamma", nil)

    family_account =
      provider_account_fixture(viewer_user_fixture())
      |> Ecto.Changeset.change(owner_user_id: user.id)
      |> Repo.update!()

    alpha_source = Repo.get_by!(GameSource, game_id: alpha.id)
    insert_library_item(family_account, alpha_source, 1_000)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/library/statuses")

    assert has_element?(view, "#status-manager")
    assert has_element?(view, "#status-filter-form")
    assert has_element?(view, "#status-search-clearable[phx-hook='ClearableSearch']")
    assert has_element?(view, "#status-search-clear[disabled]")
    assert has_element?(view, "#status-sort option[value='playtime']", "Playtime")
    assert has_element?(view, "#status-sort-direction[data-sort-direction='asc']", "Ascending")
    assert has_element?(view, "ul#status-games")
    assert has_element?(view, "#batch-status-actions")
    assert has_element?(view, "#batch-mark-playing[disabled]")
    assert has_element?(view, "#batch-mark-want-to-play[disabled]")
    assert has_element?(view, "#batch-mark-viewed[disabled]")
    assert has_element?(view, "#batch-mark-completed[disabled]")
    assert has_element?(view, "#status-filter option[value='playing']", "Playing")
    assert has_element?(view, "#status-filter option[value='backlog']", "Want to play")
    # Playtime is the viewer's own only: their linked account's 185 minutes
    # (3.1h), not the family account's separate 1000 (16.7h).
    assert has_element?(view, "#status-playtime-#{alpha.id}", "3.1h")
    refute has_element?(view, "#status-game-#{alpha.id}", "16.7h")
    refute has_element?(view, "#jump-to-top")

    assert has_element?(
             view,
             "ul#status-games > li#status-game-#{alpha.id}[phx-hook='StatusSelection'][data-game-id='#{alpha.id}']"
           )

    assert has_element?(
             view,
             "#status-game-link-#{alpha.id}[href='/games/#{alpha.slug}'][data-status-selection-ignore]"
           )

    refute has_element?(view, "#status-rating-#{alpha.id}[data-status-selection-ignore]")
    assert has_element?(view, "#status-rate-#{alpha.id}-1[data-status-selection-ignore]")

    view |> element("#status-rate-#{alpha.id}-4") |> render_click()

    assert has_element?(view, "#status-rate-#{alpha.id}-4[aria-pressed='true']")
    # Rating a game selects it so a status can be applied in the same pass.
    assert has_element?(view, "#selection-summary", "1 selected")
    assert has_element?(view, "#status-select-#{alpha.id}[checked]")

    assert Repo.get_by!(UserGameState, user_id: user.id, game_id: alpha.id).rating == 4

    view |> element("#status-half-rating-#{alpha.id}") |> render_click()

    assert has_element?(
             view,
             "#status-rate-#{alpha.id}-4 [data-rating-face='4'][data-rating-value='3.5']"
           )

    assert Repo.get_by!(UserGameState, user_id: user.id, game_id: alpha.id).rating == 3.5

    view |> element("#status-rate-#{alpha.id}-4") |> render_click()
    assert Repo.get_by!(UserGameState, user_id: user.id, game_id: alpha.id).rating == 4

    view
    |> element("#status-game-#{alpha.id}")
    |> render_hook("toggle_selection", %{id: alpha.id, selected: true})

    assert has_element?(view, "#status-select-#{alpha.id}[checked]")

    assert has_element?(view, "#status-game-#{alpha.id}[data-selected='true']")

    assert has_element?(view, "#selection-summary", "1 selected")

    view
    |> element("#status-game-#{gamma.id}")
    |> render_hook("select_range", %{id: gamma.id, selected: true})

    for game <- [alpha, beta, gamma] do
      assert has_element?(view, "#status-select-#{game.id}[checked]")
    end

    assert has_element?(view, "#selection-summary", "3 selected")
    refute has_element?(view, "#batch-mark-completed[disabled]")

    view |> element("#batch-mark-completed") |> render_click()

    assert has_element?(view, "#selection-summary", "0 selected")

    states =
      UserGameState
      |> where([state], state.user_id == ^user.id)
      |> order_by([state], asc: state.game_id)
      |> Repo.all()

    assert Enum.map(states, & &1.state) == ["completed", "completed", "completed"]
    assert Repo.get_by!(UserGameState, user_id: user.id, game_id: alpha.id).rating == 4

    view |> element("#status-rate-#{alpha.id}-4") |> render_click()
    refute has_element?(view, "#status-rate-#{alpha.id}-4[aria-pressed='true']")

    alpha_state = Repo.get_by!(UserGameState, user_id: user.id, game_id: alpha.id)
    assert alpha_state.state == "completed"
    assert is_nil(alpha_state.rating)

    view
    |> element("#status-game-#{alpha.id}")
    |> render_hook("toggle_selection", %{id: alpha.id, selected: true})

    view |> element("#batch-mark-playing") |> render_click()
    assert has_element?(view, "#status-game-#{alpha.id}", "Playing")
    assert Repo.get_by!(UserGameState, user_id: user.id, game_id: alpha.id).state == "playing"

    view
    |> element("#status-game-#{alpha.id}")
    |> render_hook("toggle_selection", %{id: alpha.id, selected: true})

    view
    |> form("#status-filter-form", filters: %{q: "gamma", status: "all", sort: "title"})
    |> render_change()

    assert_patch(view, ~p"/library/statuses?#{%{q: "gamma"}}")
    refute has_element?(view, "#status-search-clear[disabled]")
    assert has_element?(view, "#selection-summary", "0 selected")
    assert has_element?(view, "#selection-notice", "Selection cleared")
    assert has_element?(view, "#status-games", "Gamma")
    refute has_element?(view, "#status-games", "Alpha")

    view |> element("#status-sort-direction") |> render_click()
    assert_patch(view, ~p"/library/statuses?#{%{q: "gamma", direction: "desc"}}")
    assert has_element?(view, "#status-sort-direction[data-sort-direction='desc']", "Descending")
  end

  test "temporarily hides viewed games and can restore them", %{conn: conn} do
    user = viewer_user_fixture()
    account = provider_account_fixture(user)
    alpha = game_fixture(account, "Alpha", 2020)
    beta = game_fixture(account, "Beta", 2021)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/library/statuses")

    refute has_element?(view, "#restore-viewed-games")

    view
    |> element("#status-game-#{alpha.id}")
    |> render_hook("toggle_selection", %{id: alpha.id, selected: true})

    view |> element("#batch-mark-viewed") |> render_click()

    refute has_element?(view, "#status-game-#{alpha.id}")
    assert has_element?(view, "#status-game-#{beta.id}")
    assert has_element?(view, "#restore-viewed-games", "Show 1 viewed")
    assert has_element?(view, "#selection-summary", "0 selected")
    refute Repo.get_by(UserGameState, user_id: user.id, game_id: alpha.id)

    view |> element("#restore-viewed-games") |> render_click()

    assert has_element?(view, "#status-game-#{alpha.id}")
    assert has_element?(view, "#status-game-#{beta.id}")
    refute has_element?(view, "#restore-viewed-games")

    view
    |> element("#status-game-#{beta.id}")
    |> render_hook("toggle_selection", %{id: beta.id, selected: true})

    view |> element("#batch-mark-want-to-play") |> render_click()

    assert has_element?(view, "#status-game-#{beta.id}", "Want to play")
    assert Repo.get_by!(UserGameState, user_id: user.id, game_id: beta.id).state == "backlog"
  end

  test "restores the viewed set the browser remembered", %{conn: conn} do
    user = viewer_user_fixture()
    account = provider_account_fixture(user)
    alpha = game_fixture(account, "Alpha", 2020)
    beta = game_fixture(account, "Beta", 2021)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/library/statuses")

    assert has_element?(view, "#status-game-#{alpha.id}")

    # The StatusViewedStore hook replays localStorage on mount.
    render_hook(view, "sync_viewed", %{"ids" => [alpha.id]})

    refute has_element?(view, "#status-game-#{alpha.id}")
    assert has_element?(view, "#status-game-#{beta.id}")
    assert has_element?(view, "#restore-viewed-games", "Show 1 viewed")
  end

  test "selects across pages and applies one atomic batch", %{conn: conn} do
    user = viewer_user_fixture()
    account = provider_account_fixture(user)

    games =
      Enum.map(1..101, fn number ->
        title = "Paged Game #{String.pad_leading(Integer.to_string(number), 3, "0")}"
        game_fixture(account, title, 2000 + rem(number, 20))
      end)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/library/statuses")

    assert has_element?(view, "#status-pagination", "Page 1 of 2")
    view |> element("#status-select-page") |> render_click()
    assert has_element?(view, "#selection-summary", "100 selected")
    assert has_element?(view, "#status-select-page[checked]")

    view |> element("#status-next-page") |> render_click()
    assert_patch(view, ~p"/library/statuses?#{%{page: 2}}")
    assert has_element?(view, "#status-pagination", "Page 2 of 2")
    assert has_element?(view, "#selection-summary", "100 selected")

    last_game = List.last(games)

    view
    |> element("#status-game-#{last_game.id}")
    |> render_hook("toggle_selection", %{id: last_game.id, selected: true})

    assert has_element?(view, "#selection-summary", "101 selected")
    view |> element("#batch-mark-dropped") |> render_click()

    assert has_element?(view, "#selection-summary", "0 selected")

    assert Repo.aggregate(
             from(state in UserGameState,
               where: state.user_id == ^user.id and state.state == "dropped"
             ),
             :count
           ) == 101
  end

  defp provider_account_fixture(owner) do
    unique = System.unique_integer([:positive])

    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: :steam,
      external_user_id: "status-live-#{unique}",
      display_name: "Status manager library",
      sharing_policy: :selected_users
    })
    |> Ecto.Changeset.put_change(:owner_user_id, owner.id)
    |> Repo.insert!()
  end

  defp game_fixture(account, title, release_year, playtime_minutes \\ 0) do
    unique = System.unique_integer([:positive])
    normalized_title = Iri.Library.Title.normalize(title)

    game =
      %Game{}
      |> Game.changeset(%{
        title: title,
        normalized_title: normalized_title,
        slug: "status-live-game-#{unique}",
        release_year: release_year
      })
      |> Repo.insert!()

    source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: :steam,
        external_id: "status-live-game-#{unique}",
        source_title: title,
        normalized_source_title: normalized_title,
        game_id: game.id,
        catalog_kind: "game"
      })
      |> Repo.insert!()

    insert_library_item(account, source, playtime_minutes)

    game
  end

  defp insert_library_item(account, source, playtime_minutes) do
    %LibraryItem{}
    |> LibraryItem.changeset(%{
      provider_account_id: account.id,
      game_source_id: source.id,
      playtime_minutes: playtime_minutes
    })
    |> Repo.insert!()
  end
end
