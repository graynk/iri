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

defmodule IriWeb.LibraryLiveTest do
  use IriWeb.ConnCase

  import Iri.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Iri.Integrations.ProviderAccount
  alias Iri.Integrations.GOG.ClientStub, as: GOGClientStub
  alias Iri.Integrations.GOG.Reconciler, as: GOGReconciler
  alias Iri.Integrations.IGDB.{ClientStub, Enricher}
  alias Iri.Integrations.Steam.Reconciler
  alias Iri.Collections
  alias Iri.Library
  alias Iri.Library.{Game, GameSource, MediaAsset, TaxonomyTerm, UserGameState}
  alias Iri.Repo

  test "viewer browses and searches the local Steam library", %{conn: conn} do
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [
               %{"appid" => 10, "name" => "Counter-Strike", "playtime_forever" => 60},
               %{"appid" => 620, "name" => "Portal 2", "playtime_forever" => 120}
             ])

    viewer = viewer_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(viewer) |> live(~p"/library")

    assert has_element?(view, "#library-games article", "Counter-Strike")
    assert has_element?(view, "#library-games article", "Portal 2")
    assert has_element?(view, "#library-search-clearable[phx-hook='ClearableSearch']")
    assert has_element?(view, "#library-search-clear[disabled]")
    assert has_element?(view, "#bulk-edit-nav-link[href='/library/statuses']", "Bulk edit")
    assert has_element?(view, "#bulk-edit-nav-link .hero-pencil-square")
    assert has_element?(view, "#settings-nav-link[href='/settings/account']", "Settings")
    assert has_element?(view, "#bulk-edit-nav-link[class~='hover:bg-teal-400/10']")
    assert has_element?(view, "#settings-nav-link[class~='hover:bg-teal-400/10']")
    assert has_element?(view, "#library-games article[class~='hover:border-teal-300']")
    assert has_element?(view, "#add-games-link.bg-teal-300[href='/library/add']")
    assert has_element?(view, "#iri-home-link img[src='/images/iri-icon.svg']")
    assert has_element?(view, "#library-title", "Your library")

    assert has_element?(
             view,
             "#iri-source-link[href='https://github.com/graynk/iri'][target='_blank'][rel='noopener noreferrer']",
             "Source code"
           )

    refute has_element?(view, "#library-page", "Local catalog")
    assert page_title(view) == "IRI · Your game library"
    refute has_element?(view, "#manage-completion-statuses")

    view
    |> form("#library-search-form", filters: %{q: "portal"})
    |> render_change()

    assert_patch(view, ~p"/library?#{%{q: "portal"}}")
    refute has_element?(view, "#library-search-clear[disabled]")
    assert has_element?(view, "#library-games article", "Portal 2")
    refute has_element?(view, "#library-games article", "Counter-Strike")
  end

  test "library pagination keeps one URL-backed page in the stream", %{conn: conn} do
    account = steam_account_fixture()

    games =
      Enum.map(1..50, fn appid ->
        %{
          "appid" => appid,
          "name" => "Paged Game #{String.pad_leading(Integer.to_string(appid), 3, "0")}"
        }
      end)

    assert {:ok, _counts} = Reconciler.reconcile(account, games)

    viewer = viewer_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(viewer) |> live(~p"/library")

    assert has_element?(view, "#library-pagination[aria-label='Library pages']")
    assert has_element?(view, "#library-title[tabindex='-1']")

    assert has_element?(
             view,
             "#library-page-status[role='status'][aria-live='polite']",
             "Library page 1 of 2"
           )

    assert has_element?(view, "#library-page-1[aria-current='page']")
    assert has_element?(view, "#library-next-page[href='/library?page=2']")
    refute has_element?(view, "#load-more-games")
    assert has_element?(view, "#library-games article", "Paged Game 001")
    refute has_element?(view, "#library-games article", "Paged Game 049")

    view |> element("#library-next-page") |> render_click()
    assert_patch(view, ~p"/library?#{%{page: 2}}")
    assert has_element?(view, "#library-page-2[aria-current='page']")
    assert has_element?(view, "#library-page-status", "Library page 2 of 2")
    assert has_element?(view, "#library-previous-page[href='/library']")
    refute has_element?(view, "#library-games article", "Paged Game 001")
    assert has_element?(view, "#library-games article", "Paged Game 049")
    assert has_element?(view, "#library-games article", "Paged Game 050")

    view
    |> form("#library-search-form", filters: %{q: "050"})
    |> render_change()

    assert_patch(view, ~p"/library?#{%{q: "050"}}")
    refute has_element?(view, "#library-pagination")
    assert has_element?(view, "#library-games article", "Paged Game 050")
  end

  test "descending sort does not count as an applied filter", %{conn: conn} do
    viewer = viewer_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(viewer) |> live(~p"/library")

    view |> element("#library-sort-direction") |> render_click()

    assert_patch(view, ~p"/library?#{%{direction: "desc"}}")
    assert has_element?(view, "#clear-library-filters[aria-hidden='true']")
    refute has_element?(view, "#toggle-library-filters[class~='bg-teal-400/10']")
    refute has_element?(view, "#toggle-library-filters > span.rounded-full")
  end

  test "cards show the viewer's own hours, never another user's on a shared game", %{conn: conn} do
    viewer = viewer_user_fixture()
    other = viewer_user_fixture()

    own_account =
      steam_account_fixture()
      |> Ecto.Changeset.change(owner_user_id: viewer.id)
      |> Repo.update!()

    viewer =
      viewer
      |> Ecto.Changeset.change(steam_id: own_account.external_user_id)
      |> Repo.update!()

    # Another user's Steam library (shared into the household), with far more
    # hours on the same game.
    family_account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "76561198000000002",
        display_name: "Family member"
      })
      |> Ecto.Changeset.put_change(:owner_user_id, other.id)
      |> Repo.insert!()

    assert {:ok, _counts} =
             Reconciler.reconcile(own_account, [
               %{"appid" => 10, "name" => "Counter-Strike", "playtime_forever" => 60}
             ])

    assert {:ok, _counts} =
             Reconciler.reconcile(family_account, [
               %{"appid" => 10, "name" => "Counter-Strike", "playtime_forever" => 600}
             ])

    {:ok, view, _html} = conn |> log_in_user(viewer) |> live(~p"/library")

    # The viewer sees only their own 60 minutes (1.0h), not the other user's 600.
    assert has_element?(view, "#library-games article", "1.0h")
    refute has_element?(view, "#library-games article", "10.0h")
  end

  test "anonymous visitor is redirected to login", %{conn: conn} do
    # An instance that already has an account sends anonymous visitors to log
    # in; a fresh instance sends them to registration instead.
    _existing = viewer_user_fixture()

    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/library")
  end

  test "header shows completion-state totals on their own line", %{conn: conn} do
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [
               %{"appid" => 10, "name" => "Completed fixture"},
               %{"appid" => 20, "name" => "Dropped fixture"},
               %{"appid" => 30, "name" => "Playing fixture"},
               %{"appid" => 40, "name" => "Backlog fixture"}
             ])

    assert {:ok, _counts} =
             Enricher.enrich(
               %{"steam_source_id" => 1, "client_id" => "id", "access_token" => "token"},
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    viewer = viewer_user_fixture()
    scope = Iri.Accounts.Scope.for_user(viewer)

    games = Game |> Repo.all() |> Enum.sort_by(& &1.igdb_id)

    for {game, state} <-
          Enum.zip(games, ["completed", "dropped", "playing", "backlog"]) do
      assert {:ok, _state} = Library.set_game_state(scope, game.id, state)
    end

    {:ok, view, _html} = conn |> log_in_user(viewer) |> live(~p"/library")

    assert has_element?(view, "#library-completion-summary")
    assert has_element?(view, "#library-completed-count", "1 completed")
    assert has_element?(view, "#library-dropped-count", "1 dropped")
    assert has_element?(view, "#library-playing-count", "1 playing")
    assert has_element?(view, "#library-backlog-count", "1 want to play")
  end

  test "cross-store ownership renders as one canonical card with both badges", %{conn: conn} do
    steam_account = steam_account_fixture()
    gog_account = gog_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(steam_account, [%{"appid" => 10, "name" => "Shared Fixture"}])

    assert {:ok, gog_games} = GOGClientStub.fetch_library(gog_account, %{}, [])
    assert {:ok, _counts} = GOGReconciler.reconcile(gog_account, Enum.take(gog_games, 1))

    assert {:ok, _counts} =
             Enricher.enrich(
               %{
                 "steam_source_id" => 1,
                 "gog_source_id" => 5,
                 "client_id" => "id",
                 "access_token" => "token"
               },
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    viewer = viewer_user_fixture()
    scope = Iri.Accounts.Scope.for_user(viewer)
    assert {:ok, %{total_count: 1}} = Library.list_source_games(scope)

    steam_source = Repo.get_by!(GameSource, provider: :steam, external_id: "10")
    {:ok, view, _html} = conn |> log_in_user(viewer) |> live(~p"/library")
    assert has_element?(view, "#source-game-#{steam_source.id}", "Canonical Game 10010")
    assert has_element?(view, "#source-game-#{steam_source.id} span", "steam")
    assert has_element?(view, "#source-game-#{steam_source.id} span", "gog")
  end

  test "viewer filters by store, connected library, and IGDB tags", %{conn: conn} do
    steam_account = steam_account_fixture()
    gog_account = gog_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(steam_account, [%{"appid" => 620, "name" => "Steam Fixture"}])

    assert {:ok, gog_games} = GOGClientStub.fetch_library(gog_account, %{}, [])
    assert {:ok, _counts} = GOGReconciler.reconcile(gog_account, Enum.take(gog_games, 1))

    assert {:ok, _counts} =
             Enricher.enrich(
               %{
                 "steam_source_id" => 1,
                 "gog_source_id" => 5,
                 "client_id" => "id",
                 "access_token" => "token"
               },
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    extra_genre = insert_term("620", "genre", "Cozy", "70001")
    custom_tag = insert_term("620", "keyword", "Female protagonist", "70002")
    duplicate_tag = insert_term("620", "keyword", "female protagonist", "70003")
    substring_tag = insert_term("620", "keyword", "base defense", "70004")
    perspective = insert_term("620", "player_perspective", "First person", "70005")
    viewer = viewer_user_fixture()
    scope = Iri.Accounts.Scope.for_user(viewer)
    assert {:ok, options} = Library.list_filter_options(scope)
    genre = Enum.find(options.genres, &(&1.name == "Role-playing (RPG)"))

    {:ok, view, _html} = conn |> log_in_user(viewer) |> live(~p"/library")
    assert has_element?(view, "#library-filter-panel")
    assert has_element?(view, "#library-search-control")
    assert has_element?(view, "#library-toolbar-actions #library-sort")
    assert has_element?(view, "#library-toolbar-actions #toggle-library-filters")
    assert has_element?(view, "#library-filter-stores input[type='checkbox'][value='gog']")
    assert has_element?(view, "#library-sort")
    assert has_element?(view, "#library-filter-controllers")
    assert has_element?(view, "#library-filter-deck input[value='ideal']")
    assert has_element?(view, "#library-filter-deck input[value='playable']")
    refute has_element?(view, "#library-filter-protondb")
    assert has_element?(view, "#library-filter-panel > #library-filter-tags:last-child")
    assert has_element?(view, "#library-filter-tags input[name='filters[tag_search]']")

    assert has_element?(
             view,
             "#library-filter-stores[phx-hook='IriWeb.LibraryLive.PersistentFilterGroup']"
           )

    assert has_element?(view, "#library-filter-platforms")
    assert has_element?(view, "#library-filter-modes input[value='vr']")

    assert has_element?(
             view,
             "#library-filter-stores + #library-filter-platforms + #library-filter-genres + #library-filter-modes"
           )

    assert has_element?(
             view,
             "#library-filter-deck + #library-filter-themes + #library-filter-tags"
           )

    assert has_element?(
             view,
             "#library-filter-statuses label:last-child input[value='not_played']"
           )

    assert has_element?(view, "#library-filter-statuses input[value='playing']")
    assert has_element?(view, "#library-filter-statuses input[value='backlog']")

    assert has_element?(view, "#library-filter-panel.hidden")

    view |> element("#toggle-library-filters") |> render_click()
    refute has_element?(view, "#library-filter-panel.hidden")

    view
    |> form("#library-search-form", filters: %{providers: ["gog"]})
    |> render_change()

    assert_patch(view, ~p"/library?#{%{providers: ["gog"]}}")
    assert has_element?(view, "#library-games article", "Canonical Game 10010")
    refute has_element?(view, "#library-games article", "Canonical Game 10620")
    assert has_element?(view, "#library-filter-stores[open]")

    render_change(view, "filter", %{
      "_target" => ["filters", "sort"],
      "filters" => %{"sort" => "rating"}
    })

    assert_patch(
      view,
      ~p"/library?#{%{providers: ["gog"], sort: "rating"}}"
    )

    view |> element("#library-sort-direction") |> render_click()

    assert_patch(
      view,
      ~p"/library?#{%{providers: ["gog"], sort: "rating", direction: "desc"}}"
    )

    assert has_element?(view, "#library-sort-direction[data-sort-direction='desc']", "Descending")

    assert has_element?(view, "#library-games article", "Canonical Game 10010")
    refute has_element?(view, "#library-games article", "Canonical Game 10620")

    view
    |> form("#library-search-form",
      filters: %{providers: [], account_ids: [Integer.to_string(steam_account.id)]}
    )
    |> render_change()

    assert has_element?(view, "#library-games article", "Canonical Game 10620")
    refute has_element?(view, "#library-games article", "Canonical Game 10010")

    view
    |> form("#library-search-form",
      filters: %{
        account_ids: [],
        genre_ids: [Integer.to_string(genre.id), Integer.to_string(extra_genre.id)]
      }
    )
    |> render_change()

    refute has_element?(view, "#library-games article", "Canonical Game 10010")
    assert has_element?(view, "#library-games article", "Canonical Game 10620")

    render_change(view, "filter", %{
      "_target" => ["filters", "tag_search"],
      "filters" => %{"tag_search" => "fe"}
    })

    assert has_element?(view, "#add-tag-#{custom_tag.id}", custom_tag.name)
    refute has_element?(view, "#add-tag-#{duplicate_tag.id}")
    assert has_element?(view, "#add-tag-#{substring_tag.id}", "Base defense")

    assert has_element?(
             view,
             "#tag-suggestions > button:first-child#add-tag-#{custom_tag.id}",
             "Female protagonist"
           )

    refute has_element?(view, "#library-games article", "Canonical Game 10010")
    assert has_element?(view, "#library-games article", "Canonical Game 10620")

    view |> element("#add-tag-#{custom_tag.id}") |> render_click()

    assert has_element?(view, "#library-games article", "Canonical Game 10620")
    refute has_element?(view, "#library-games article", "Canonical Game 10010")
    assert has_element?(view, "#remove-tag-#{custom_tag.id}", custom_tag.name)
    assert has_element?(view, "#clear-library-filters[aria-hidden='false']")

    view |> element("#remove-tag-#{custom_tag.id}") |> render_click()

    refute has_element?(view, "#library-games article", "Canonical Game 10010")
    assert has_element?(view, "#library-games article", "Canonical Game 10620")

    render_change(view, "filter", %{
      "_target" => ["filters", "tag_search"],
      "filters" => %{"tag_search" => "first person"}
    })

    assert has_element?(view, "#add-tag-#{perspective.id}", "First person")
    view |> element("#add-tag-#{perspective.id}") |> render_click()
    assert has_element?(view, "#remove-tag-#{perspective.id}", "First person")
    assert has_element?(view, "#library-games article", "Canonical Game 10620")
    refute has_element?(view, "#library-games article", "Canonical Game 10010")
    view |> element("#remove-tag-#{perspective.id}") |> render_click()

    view
    |> form("#library-search-form",
      filters: %{genre_ids: [], providers: ["steam", "gog"]}
    )
    |> render_change()

    assert has_element?(view, "#library-games article", "Canonical Game 10010")
    assert has_element?(view, "#library-games article", "Canonical Game 10620")
  end

  test "viewer opens a canonical IGDB detail page from a library card", %{conn: conn} do
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [
               %{
                 "appid" => 10,
                 "name" => "Store Name",
                 "playtime_forever" => 860
               }
             ])

    assert {:ok, _counts} =
             Enricher.enrich(
               %{"steam_source_id" => 1, "client_id" => "id", "access_token" => "token"},
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    [local_screenshot, remote_screenshot, _video] = insert_media_fixture("10")

    local_screenshot =
      local_screenshot
      |> MediaAsset.changeset(%{
        cache_status: "ready",
        local_path: "screenshots/missing-fixture.jpg"
      })
      |> Repo.update!()

    insert_battle_royale_term("10")
    source = Repo.get_by!(GameSource, provider: :steam, external_id: "10")

    viewer = viewer_user_fixture()
    scope = Iri.Accounts.Scope.for_user(viewer)
    {:ok, favorites} = Collections.create_collection(scope, %{name: "Favorites"})
    {:ok, backlog} = Collections.create_collection(scope, %{name: "Backlog"})
    assert {:ok, 1} = Collections.add_games(scope, favorites.id, [source.game_id])

    {:ok, library, _html} = conn |> log_in_user(viewer) |> live(~p"/library")
    assert has_element?(library, "#library-games article", "Canonical Game 10010")
    # The account is not the viewer's own, so its hours are not shown to them.
    refute has_element?(library, "#library-games article", "14.3h")
    assert has_element?(library, "a[href='/games/canonical-game-10010-10010']")
    assert has_element?(library, "#library-page[phx-hook='LibraryHistory']")
    assert has_element?(library, "[data-library-game-link]")

    assert has_element?(
             library,
             "#source-game-#{source.id}[data-gamepad-card][data-gamepad-selected='false']"
           )

    assert has_element?(
             library,
             "#source-game-#{source.id}[phx-hook='IriWeb.LibraryLive.CardPreview']"
           )

    assert has_element?(
             library,
             "#source-game-#{source.id} #game-card-title-#{source.id} [data-library-game-link][data-gamepad-item]",
             "Canonical Game 10010"
           )

    refute has_element?(library, "#card-preview-#{source.id}[phx-hook]")

    assert has_element?(
             library,
             "#card-preview-#{source.id} [data-card-preview-frame][data-src='/media/#{local_screenshot.id}']"
           )

    assert has_element?(
             library,
             "#card-preview-#{source.id} [data-card-preview-frame][data-src='#{remote_screenshot.remote_url}']"
           )

    assert has_element?(library, "#card-preview-#{source.id} [data-card-preview-frame]")

    assert has_element?(
             library,
             "#card-preview-#{source.id} [data-card-preview-image][src^='data:image/gif'][alt=''][aria-hidden='true']"
           )

    assert has_element?(
             library,
             "#card-preview-#{source.id} [data-card-preview-backdrop][src^='data:image/gif'][alt=''][aria-hidden='true']"
           )

    assert has_element?(library, "#card-preview-#{source.id} [data-src*='screen-fixture-2']")
    assert has_element?(library, "#card-footer-#{source.id}")
    assert has_element?(library, "[aria-label='Metadata rating: 89%']")
    assert has_element?(library, "#library-sort option[value='rating']", "Metadata rating")
    assert has_element?(library, "#library-sort option[value='my_rating']", "My rating")
    assert has_element?(library, "#library-sort option[value='playtime']", "Playtime")
    assert has_element?(library, "#library-sort option[value='release_date']", "Release date")

    assert has_element?(
             library,
             "#library-sort-direction[data-sort-direction='asc']",
             "Ascending"
           )

    assert has_element?(library, "#iri-home-link[phx-hook='LibraryLink']")

    assert has_element?(
             library,
             "#jump-to-top[phx-hook='JumpToTop'][data-jump-visible='false']"
           )

    refute has_element?(library, "#library-filter-modes", "Battle Royale")

    {:ok, detail, _html} =
      conn |> log_in_user(viewer) |> live(~p"/games/canonical-game-10010-10010")

    assert has_element?(detail, "#game-title", "Canonical Game 10010")
    # The account is not the viewer's own, so only the catalog estimate is shown.
    assert has_element?(detail, "#game-playtime")
    refute has_element?(detail, "#my-playtime")
    assert has_element?(detail, "#game-time-to-beat", "5-13 hours")
    assert has_element?(detail, "span", "Role-playing (RPG)")
    refute has_element?(detail, "span", "Battle Royale")

    assert has_element?(
             detail,
             "#install-steam-10.min-h-10.border[href='steam://install/10']"
           )

    assert has_element?(
             detail,
             "#store-link-steam.min-h-10.border[href='https://store.steampowered.com/app/10']"
           )

    assert has_element?(detail, "#game-media-column")
    assert has_element?(detail, "#jump-to-top[phx-hook='JumpToTop']")
    refute has_element?(detail, "#game-back-to-library")
    assert has_element?(detail, "#game-title-block #game-title")

    assert has_element?(
             detail,
             "#game-title-block[class~='lg:self-stretch'] #game-primary-actions[class~='xl:justify-end']"
           )

    assert has_element?(detail, "main#main-content #game-content-column")
    refute has_element?(detail, "main main")
    assert has_element?(detail, "#game-title-block #game-byline")
    assert has_element?(detail, "#game-personal-rail #my-game-log")

    assert has_element?(
             detail,
             "#game-metadata-rating[class~='bg-emerald-400/10'] .hero-hand-thumb-up"
           )

    assert has_element?(
             detail,
             "#open-screenshot-0[class~='hover:border-teal-300'][class~='hover:ring-teal-300']"
           )

    assert has_element?(
             detail,
             "#open-screenshot-0 img[src='/media/#{local_screenshot.id}']"
           )

    assert has_element?(
             detail,
             "#open-screenshot-1 img[src='#{remote_screenshot.remote_url}']"
           )

    assert has_element?(detail, "#game-trailers #load-trailer-0", "Trailer 1")
    assert has_element?(detail, "#game-screenshot-strip #open-screenshot-0")
    assert has_element?(detail, "#game-screenshots + #game-trailers")
    assert has_element?(detail, "#game-genres", "Role-playing (RPG)")
    assert has_element?(detail, "#game-tags", "Science fiction")
    refute has_element?(detail, "#game-tags", "Role-playing (RPG)")
    assert has_element?(detail, "#personal-rating")

    assert has_element?(
             detail,
             "#game-collection-picker > summary.text-teal-200",
             "In 1 collection"
           )

    assert has_element?(detail, "#game-collection-form")
    assert has_element?(detail, "#game-collection-#{favorites.id}[checked]")
    refute has_element?(detail, "#game-collection-#{backlog.id}[checked]")
    assert has_element?(detail, "#personal-rating [data-rating-face='1']")
    assert has_element?(detail, "#personal-rating [data-rating-face='5']")
    assert has_element?(detail, "#rate-game-3-5[aria-label='3.5 out of 5: Liked']")
    refute has_element?(detail, "#personal-rating input[type='radio'][checked]")
    refute has_element?(detail, "#clear-personal-rating")
    assert has_element?(detail, "#my-game-log #personal-note")
    assert has_element?(detail, "#personal-note-form")
    assert has_element?(detail, "#personal-note h3", "Note")
    assert has_element?(detail, "#personal-note-input[phx-blur='save_note']")
    refute has_element?(detail, "#personal-note summary")
    refute has_element?(detail, "#save-personal-note")
    refute has_element?(detail, "#clear-personal-note")
    refute has_element?(detail, "#clear-game-state")
    refute has_element?(detail, "#screenshot-viewer")
    assert has_element?(detail, "#open-screenshot-0[phx-click*='push_focus']")

    assert has_element?(
             detail,
             "#game-state-controls[role='group'][aria-label='Completion status']"
           )

    refute has_element?(detail, "#game-state-controls [role='radio']")
    assert has_element?(detail, "#mark-game-want-to-play[aria-pressed='false']")
    detail |> element("#mark-game-want-to-play") |> render_click()
    assert has_element?(detail, "#mark-game-want-to-play[aria-pressed='true']")

    detail |> element("#mark-game-playing") |> render_click()
    assert has_element?(detail, "#mark-game-playing[aria-pressed='true']")
    assert has_element?(detail, "#mark-game-want-to-play[aria-pressed='false']")
    assert has_element?(detail, "#mark-game-completed[aria-pressed='false']")

    detail
    |> form("#game-collection-form",
      collections: %{collection_ids: [Integer.to_string(backlog.id)]}
    )
    |> render_submit()

    assert has_element?(detail, "#game-collection-picker > summary", "In 1 collection")
    refute has_element?(detail, "#game-collection-#{favorites.id}[checked]")
    assert has_element?(detail, "#game-collection-#{backlog.id}[checked]")

    assert {:ok, _collection, backlog_entries} =
             Collections.list_collection_games(scope, backlog.id)

    assert Enum.map(backlog_entries, & &1.game_id) == [source.game_id]

    assert {:ok, _collection, []} = Collections.list_collection_games(scope, favorites.id)

    detail |> element("#open-screenshot-0") |> render_click()
    assert has_element?(detail, "#screenshot-viewer[role='dialog'][phx-remove*='pop_focus']")
    assert has_element?(detail, "#screenshot-viewer img[src='/media/#{local_screenshot.id}']")
    assert has_element?(detail, "#close-screenshot-viewer[data-dialog-close]")
    detail |> element("#close-screenshot-viewer") |> render_click()
    refute has_element?(detail, "#screenshot-viewer")

    assert has_element?(detail, "#load-trailer-0")
    assert has_element?(detail, "#load-trailer-0[phx-click*='push_focus']")
    refute has_element?(detail, "#trailer-iframe")
    detail |> element("#load-trailer-0") |> render_click()

    assert has_element?(
             detail,
             "#trailer-iframe[src*='youtube-nocookie.com/embed/video-fixture']"
           )

    assert has_element?(detail, "#trailer-viewer[phx-remove*='pop_focus']")
    assert has_element?(detail, "#close-trailer-viewer[data-dialog-close]")

    detail |> element("#mark-game-completed") |> render_click()
    assert has_element?(detail, "#mark-game-completed[aria-pressed='true']")
    assert has_element?(detail, "#mark-game-dropped[aria-pressed='false']")
    refute has_element?(detail, "#clear-game-state")
    refute has_element?(detail, "#mark-game-not-played")

    detail
    |> form("#personal-rating", rating: %{value: "3.5"})
    |> render_change()

    assert has_element?(detail, "#rate-game-3-5[checked]")
    assert has_element?(detail, "[data-rating-face='4'][data-rating-value='3.5']")

    assert Repo.get_by!(UserGameState, user_id: viewer.id, game_id: source.game_id).rating ==
             3.5

    detail
    |> form("#personal-rating", rating: %{value: "5"})
    |> render_change()

    assert has_element?(detail, "#rate-game-5[checked]")
    assert has_element?(detail, "#clear-personal-rating")
    assert has_element?(detail, "#rating-feedback", "Rating saved")

    detail
    |> element("#personal-note-input")
    |> render_blur(%{"value" => "  A personal note.  "})

    assert has_element?(detail, "#personal-note-input", "A personal note.")
    assert has_element?(detail, "#note-feedback", "Note saved")

    preferences =
      Repo.get_by!(UserGameState, user_id: viewer.id, game_id: source.game_id)

    assert preferences.state == "completed"
    assert preferences.rating == 5
    assert preferences.notes == "A personal note."

    {:ok, rated_library, _html} = conn |> log_in_user(viewer) |> live(~p"/library")

    assert has_element?(
             rated_library,
             "[aria-label='My rating: 5 out of 5 — Amazing'] [data-rating-face='5']"
           )

    library
    |> form("#library-search-form", filters: %{states: ["completed"]})
    |> render_change()

    assert has_element?(library, "#library-games article", "Canonical Game 10010")

    library
    |> form("#library-search-form", filters: %{states: ["dropped"]})
    |> render_change()

    refute has_element?(library, "#library-games article", "Canonical Game 10010")

    detail |> element("#mark-game-completed") |> render_click()
    assert has_element?(detail, "#mark-game-completed[aria-pressed='false']")
    refute has_element?(detail, "#clear-game-state")
    assert has_element?(detail, "#rate-game-5[checked]")
    assert has_element?(detail, "#personal-note-input", "A personal note.")

    preferences =
      Repo.get_by!(UserGameState, user_id: viewer.id, game_id: source.game_id)

    assert preferences.state == nil
    assert preferences.rating == 5
    assert preferences.notes == "A personal note."

    detail |> element("#clear-personal-rating") |> render_click()
    refute has_element?(detail, "#personal-rating input[type='radio'][checked]")

    assert Repo.get_by!(UserGameState, user_id: viewer.id, game_id: source.game_id).notes ==
             "A personal note."

    detail |> element("#personal-note-input") |> render_blur(%{"value" => ""})
    refute Repo.get_by(UserGameState, user_id: viewer.id, game_id: source.game_id)
    refute has_element?(detail, "#clear-personal-note")
    refute has_element?(detail, "#personal-note-input", "A personal note.")
  end

  test "blur mode obscures covers and screenshots and disables card previews", %{conn: conn} do
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 10, "name" => "Sensitive fixture"}])

    assert {:ok, _counts} =
             Enricher.enrich(
               %{"steam_source_id" => 1, "client_id" => "id", "access_token" => "token"},
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    insert_media_fixture("10")
    source = Repo.get_by!(GameSource, provider: :steam, external_id: "10")

    %MediaAsset{}
    |> MediaAsset.changeset(%{
      game_id: source.game_id,
      kind: "cover",
      source: "test",
      remote_id: "sensitive-cover",
      local_path: "/tmp/sensitive-cover.jpg",
      cache_status: "ready"
    })
    |> Repo.insert!()

    Game
    |> Repo.get!(source.game_id)
    |> Ecto.Changeset.change(nsfw: true)
    |> Repo.update!()

    source
    |> Ecto.Changeset.change(nsfw: true)
    |> Repo.update!()

    viewer = viewer_user_fixture()
    user_conn = log_in_user(conn, viewer)
    {:ok, library, _html} = live(user_conn, ~p"/library")

    assert has_element?(
             library,
             "#card-preview-#{source.id}[data-sensitive-carousel='disabled']"
           )

    assert has_element?(
             library,
             "#source-game-#{source.id}[phx-hook='IriWeb.LibraryLive.CardPreview']"
           )

    refute has_element?(library, "#card-preview-#{source.id} [data-card-preview-frame]")

    assert has_element?(
             library,
             "#card-preview-#{source.id} img[data-sensitive-media='blurred']"
           )

    {:ok, detail, _html} = live(user_conn, ~p"/games/canonical-game-10010-10010")
    assert has_element?(detail, "#game-cover[data-sensitive-media='blurred']")

    assert has_element?(
             detail,
             "#game-screenshots img[data-sensitive-media='blurred']"
           )

    refute has_element?(detail, "#reveal-sensitive-cover > *")
    refute has_element?(detail, "#open-screenshot-0 > span")
    refute has_element?(detail, "#sensitive-media-admin-control")
    refute has_element?(detail, "#fix-match")

    detail |> element("#reveal-sensitive-cover") |> render_click()
    refute has_element?(detail, "#reveal-sensitive-cover")
    refute has_element?(detail, "#game-cover[data-sensitive-media='blurred']")
    refute has_element?(detail, "#game-screenshots img[data-sensitive-media='blurred']")

    detail |> element("#open-screenshot-0") |> render_click()
    assert has_element?(detail, "#screenshot-viewer")

    admin = admin_user_fixture()
    admin_conn = log_in_user(conn, admin)
    {:ok, admin_detail, _html} = live(admin_conn, ~p"/games/canonical-game-10010-10010")
    assert has_element?(admin_detail, "#mark-game-not-sensitive")
    assert has_element?(admin_detail, "#game-log-footer #sensitive-media-admin-control")
    assert has_element?(admin_detail, "#fix-match", "Fix match")

    admin_detail |> element("#mark-game-not-sensitive") |> render_click()
    refute Repo.get!(Game, source.game_id).nsfw
    assert has_element?(admin_detail, "#mark-game-sensitive", "Mark as NSFW")
    refute has_element?(admin_detail, "#game-cover[data-sensitive-media='blurred']")

    admin_detail |> element("#mark-game-sensitive") |> render_click()
    assert Repo.get!(Game, source.game_id).nsfw
    assert has_element?(admin_detail, "#mark-game-not-sensitive")
    assert has_element?(admin_detail, "#game-cover[data-sensitive-media='blurred']")
  end

  defp steam_account_fixture do
    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: :steam,
      external_user_id: "76561198000000001",
      display_name: "Fixture owner"
    })
    |> Repo.insert!()
  end

  defp gog_account_fixture do
    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: :gog,
      external_user_id: "48628349971017",
      display_name: "GOG owner"
    })
    |> Repo.insert!()
  end

  defp insert_media_fixture(external_id) do
    source = Repo.get_by!(GameSource, provider: :steam, external_id: external_id)

    for attrs <- [
          %{
            kind: "screenshot",
            source: "igdb",
            remote_id: "screen-fixture",
            remote_url:
              "https://images.igdb.com/igdb/image/upload/t_screenshot_big/screen-fixture.jpg"
          },
          %{
            kind: "screenshot",
            source: "igdb",
            remote_id: "screen-fixture-2",
            remote_url:
              "https://images.igdb.com/igdb/image/upload/t_screenshot_big/screen-fixture-2.jpg",
            position: 1
          },
          %{
            kind: "video",
            source: "igdb",
            remote_id: "video-fixture",
            remote_url: "https://www.youtube.com/watch?v=video-fixture"
          }
        ] do
      %MediaAsset{}
      |> MediaAsset.changeset(Map.put(attrs, :game_id, source.game_id))
      |> Repo.insert!()
    end
  end

  defp insert_battle_royale_term(external_id) do
    insert_term(external_id, "game_mode", "Battle Royale", "99999")
  end

  defp insert_term(external_id, kind, name, term_external_id) do
    source = Repo.get_by!(GameSource, provider: :steam, external_id: external_id)

    term =
      %TaxonomyTerm{}
      |> TaxonomyTerm.changeset(%{
        source: "igdb",
        external_id: term_external_id,
        kind: kind,
        name: name,
        slug: Iri.Library.Title.slug(name)
      })
      |> Repo.insert!()

    Repo.insert_all("game_terms", [%{game_id: source.game_id, taxonomy_term_id: term.id}])
    term
  end
end
