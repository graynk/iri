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

defmodule IriWeb.CollectionLiveTest do
  use IriWeb.ConnCase

  import Iri.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Iri.Accounts.Scope
  alias Iri.Collections
  alias Iri.Collections.Collection
  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{Game, GameSource, LibraryItem, Personalization}
  alias Iri.Repo

  test "private collection routes require authentication while shared URLs are anonymous", %{
    conn: conn
  } do
    # An instance that already has an account sends anonymous visitors to log
    # in; a fresh instance sends them to registration instead.
    _existing = viewer_user_fixture()

    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/collections")

    shared_path = "/collections/shared?share_token=sensitive-capability"
    conn = get(conn, shared_path)

    assert html_response(conn, 200) =~ "Collection not found"
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]

    assert Phoenix.Logger.filter_values(%{"share_token" => "sensitive-capability"}) == %{
             "share_token" => "[FILTERED]"
           }
  end

  test "creates a collection, navigates to edit, and reports duplicate names", %{conn: conn} do
    user = viewer_user_fixture()
    conn = log_in_user(conn, user)

    {:ok, index, _html} = live(conn, ~p"/collections")
    assert has_element?(index, "#collections-index")
    assert has_element?(index, "#collections-empty")
    assert has_element?(index, "#new-collection.bg-teal-300")
    assert has_element?(index, "#collections-index header .text-teal-100", "Personal lists")
    assert has_element?(index, "#collections-nav-link[href='/collections']")
    assert has_element?(index, "section[aria-labelledby='your-collections-heading']")
    assert has_element?(index, "#your-collections-heading", "Your collections")

    {:ok, form_view, _html} = live(conn, ~p"/collections/new")

    form_view
    |> form("#collection-form", collection: %{name: "Favorite RPGs"})
    |> render_submit()

    collection = Repo.get_by!(Collection, user_id: user.id, name: "Favorite RPGs")
    assert_redirect(form_view, ~p"/collections/#{collection.id}/edit")

    {:ok, duplicate, _html} = live(conn, ~p"/collections/new")

    duplicate
    |> form("#collection-form", collection: %{name: "favorite rpgs"})
    |> render_submit()

    assert has_element?(duplicate, "#collection-form [name='collection[name]']")
    assert has_element?(duplicate, "#collection-form", "has already been taken")

    assert has_element?(
             duplicate,
             "#collection-name[aria-invalid='true'][aria-describedby='collection-name-errors']"
           )

    assert has_element?(duplicate, "#collection-name-errors", "has already been taken")
  end

  test "Family mode shows other family members' public collections at the bottom", %{conn: conn} do
    previous_mode = Application.get_env(:iri, :mode)
    Application.put_env(:iri, :mode, :family)
    on_exit(fn -> Application.put_env(:iri, :mode, previous_mode) end)

    viewer = viewer_user_fixture()
    owner = viewer_user_fixture()
    owner_scope = Scope.for_user(owner)
    game = game_fixture(provider_account_fixture(owner), "Shared family game")

    {:ok, public_collection} =
      Collections.create_collection(owner_scope, %{name: "Family picks"})

    {:ok, private_collection} =
      Collections.create_collection(owner_scope, %{name: "Owner private"})

    assert {:ok, 1} = Collections.add_games(owner_scope, public_collection.id, [game.id])
    assert {:ok, _collection} = Collections.enable_sharing(owner_scope, public_collection.id)

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/collections")

    assert has_element?(view, "#family-public-collections")
    assert has_element?(view, "#family-collections")
    assert has_element?(view, "#family-collection-#{public_collection.id}", "Family picks")
    assert has_element?(view, "#family-collection-#{public_collection.id}", owner.username)
    assert has_element?(view, "#family-collection-#{public_collection.id}", "1 game")

    assert has_element?(
             view,
             "#family-collection-#{public_collection.id} > [data-collection-cover]"
           )

    assert has_element?(
             view,
             "#open-family-collection-#{public_collection.id}[href^='/collections/shared?share_token='][data-gamepad-item][aria-label='Open Family picks']"
           )

    refute has_element?(view, "#family-collection-#{private_collection.id}")
    refute has_element?(view, "#edit-collection-#{public_collection.id}")

    Application.put_env(:iri, :mode, :public)

    {:ok, public_mode_view, _html} =
      conn
      |> recycle()
      |> log_in_user(viewer)
      |> live(~p"/collections")

    refute has_element?(public_mode_view, "#family-public-collections")
  end

  test "searches, multi-adds, renames, removes, and deletes a collection", %{conn: conn} do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)
    account = provider_account_fixture(user)
    alpha = game_fixture(account, "Alpha")
    beta = game_fixture(account, "Beta")
    {:ok, collection} = Collections.create_collection(scope, %{name: "Working title"})
    user_conn = log_in_user(conn, user)
    {:ok, view, _html} = live(user_conn, ~p"/collections/#{collection.id}/edit")

    assert has_element?(view, "#collection-edit")
    assert has_element?(view, "#collection-search[autofocus]")
    assert has_element?(view, "#collection-search-clearable[phx-hook='ClearableSearch']")
    assert has_element?(view, "#collection-search-clear[disabled]")

    view
    |> form("#collection-search-form", search: %{q: "a"})
    |> render_change()

    refute has_element?(view, "#collection-search-clear[disabled]")

    assert has_element?(view, "#collection-search-game-#{alpha.id}")
    assert has_element?(view, "#collection-search-game-#{beta.id}")

    view |> element("#select-collection-game-#{alpha.id}") |> render_click()
    view |> element("#select-collection-game-#{beta.id}") |> render_click()
    assert has_element?(view, "#add-selected-games", "Add 2 selected")
    view |> element("#add-selected-games") |> render_click()

    assert has_element?(view, "#collection-current-games", "Alpha")
    assert has_element?(view, "#collection-current-games", "Beta")
    assert has_element?(view, "#collection-search-game-#{alpha.id}", "Added")
    assert has_element?(view, "#collection-feedback", "Added 2 games")
    assert has_element?(view, "#collection-current-games[phx-hook='CollectionReorder']")

    assert has_element?(
             view,
             "#collection-current-games [data-reorder-row][data-game-id='#{alpha.id}'] [data-reorder-handle]"
           )

    assert has_element?(view, "#move-collection-game-up-#{alpha.id}[disabled]")
    assert has_element?(view, "#move-collection-game-down-#{beta.id}[disabled]")

    render_hook(view, "reorder_game", %{
      "moved_id" => Integer.to_string(beta.id),
      "before_id" => Integer.to_string(alpha.id)
    })

    assert current_game_order(view) == [beta.id, alpha.id]
    assert has_element?(view, "#collection-order-feedback", "Order saved")

    view |> element("#move-collection-game-down-#{beta.id}") |> render_click()
    assert current_game_order(view) == [alpha.id, beta.id]

    view |> element("#move-collection-game-up-#{beta.id}") |> render_click()
    assert current_game_order(view) == [beta.id, alpha.id]

    assert has_element?(
             view,
             "#collection-entry-comment-#{beta.id}[phx-blur='save_entry_comment'][phx-value-id='#{beta.id}']"
           )

    refute has_element?(view, "#save-collection-entry-comment-#{beta.id}")

    view
    |> element("#collection-entry-comment-#{beta.id}")
    |> render_blur(%{"value" => "Best played co-op"})

    assert has_element?(view, "#collection-feedback", "Comment saved")

    {:ok, show, _html} = live(user_conn, ~p"/collections/#{collection.id}")
    assert has_element?(show, "#collection-games", "Best played co-op")
    assert has_element?(show, "#export-collection-csv[download]")
    assert has_element?(show, "#export-collection-txt[download]")
    assert has_element?(show, "#export-collection-html[download][href$='/export.zip']", "HTML")
    assert has_element?(show, "#export-collection-html-help[role='tooltip']")
    assert has_element?(show, "#collection-sort-title")
    assert has_element?(show, "#collection-sort-year")
    assert has_element?(show, "#collection-sort-igdb")
    assert has_element?(show, "#collection-sort-mine")
    refute has_element?(show, "#collection-sort-custom")
    collection_updated_at = Repo.get!(Collection, collection.id).updated_at

    show |> element("#collection-sort-title") |> render_click()

    assert_patch(
      show,
      ~p"/collections/#{collection.id}?#{%{sort: "title", direction: "desc"}}"
    )

    show |> element("#collection-sort-title") |> render_click()

    assert_patch(
      show,
      ~p"/collections/#{collection.id}?#{%{sort: "title", direction: "asc"}}"
    )

    show |> element("#collection-sort-title") |> render_click()
    assert_patch(show, ~p"/collections/#{collection.id}")

    show |> element("#collection-sort-year") |> render_click()

    assert_patch(
      show,
      ~p"/collections/#{collection.id}?#{%{sort: "release_year", direction: "desc"}}"
    )

    assert Repo.get!(Collection, collection.id).updated_at == collection_updated_at

    view
    |> form("#collection-name-form", collection: %{name: "Finished list"})
    |> render_submit()

    assert has_element?(view, "#collection-feedback", "Name saved")
    assert Repo.get!(Collection, collection.id).name == "Finished list"

    view |> element("#remove-collection-game-#{alpha.id}") |> render_click()
    refute has_element?(view, "#remove-collection-game-#{alpha.id}")
    assert has_element?(view, "#remove-collection-game-#{beta.id}")

    view
    |> form("#delete-collection-form", delete: %{name: "wrong"})
    |> render_submit()

    assert has_element?(view, "#delete-collection-error")

    view
    |> form("#delete-collection-form", delete: %{name: "Finished list"})
    |> render_submit()

    assert_redirect(view, ~p"/collections")
    refute Repo.get(Collection, collection.id)
  end

  test "private URLs stay private and shared pages expose only the safe read-only projection", %{
    conn: conn
  } do
    owner = viewer_user_fixture()
    viewer = viewer_user_fixture()
    owner_scope = Scope.for_user(owner)
    game = game_fixture(provider_account_fixture(owner), "Owner-only game")
    {:ok, collection} = Collections.create_collection(owner_scope, %{name: "Recommendations"})
    assert {:ok, 1} = Collections.add_games(owner_scope, collection.id, [game.id])

    assert {:ok, _entry} =
             Collections.update_entry_comment(
               owner_scope,
               collection.id,
               game.id,
               "Visible collection comment"
             )

    assert {:ok, _state} = Personalization.set_rating(owner_scope, game.id, 5)
    assert {:ok, _state} = Personalization.set_note(owner_scope, game.id, "Never disclose this")

    viewer_conn = log_in_user(conn, viewer)

    assert {:error, {:live_redirect, %{to: "/collections"}}} =
             live(viewer_conn, ~p"/collections/#{collection.id}")

    owner_conn = log_in_user(build_conn(), owner)
    {:ok, edit, _html} = live(owner_conn, ~p"/collections/#{collection.id}/edit")
    edit |> element("#enable-collection-sharing") |> render_click()

    assert has_element?(edit, "#collection-share-url")
    assert has_element?(edit, "#collection-share-url[value]")
    share_url = input_value(edit, "#collection-share-url")
    share_uri = URI.parse(share_url)
    shared_path = share_uri.path <> "?" <> share_uri.query
    share_token = URI.decode_query(share_uri.query)["share_token"]

    {:ok, shared, _html} = live(viewer_conn, shared_path)
    assert has_element?(shared, "#shared-collection")
    assert has_element?(shared, "#shared-collection-games", "Owner-only game")
    assert has_element?(shared, "#shared-collection-games", "Visible collection comment")
    assert has_element?(shared, "#shared-collection-games [data-rating-face='5']")
    assert has_element?(shared, "#shared-collection-games p", "Owner-only game")
    assert has_element?(shared, "#shared-collection-sort-title")
    assert has_element?(shared, "#shared-collection-sort-year")
    assert has_element?(shared, "#shared-collection-sort-igdb")
    refute has_element?(shared, "#shared-collection-sort-custom")

    assert has_element?(
             shared,
             "#shared-collection-sort-owner-rating",
             "#{owner.username}'s rating"
           )

    refute has_element?(shared, "#shared-collection-games a[href='/games/#{game.slug}']")
    refute has_element?(shared, "#edit-collection")
    refute has_element?(shared, "#collection-search")
    refute has_element?(shared, "#personal-note")
    refute has_element?(shared, "#game-state-controls")
    refute has_element?(shared, "#game-playtime")
    refute has_element?(shared, "[data-reorder-handle]")

    shared |> element("#shared-collection-sort-title") |> render_click()

    assert_patch(
      shared,
      ~p"/collections/shared?#{%{share_token: share_token, sort: "title", direction: "desc"}}"
    )

    shared |> element("#shared-collection-sort-title") |> render_click()

    assert_patch(
      shared,
      ~p"/collections/shared?#{%{share_token: share_token, sort: "title", direction: "asc"}}"
    )

    shared |> element("#shared-collection-sort-title") |> render_click()

    assert_patch(
      shared,
      ~p"/collections/shared?#{%{share_token: share_token, sort: "custom", direction: "asc"}}"
    )

    edit |> element("#disable-collection-sharing") |> render_click()
    {:ok, revoked, _html} = live(viewer_conn, shared_path)
    assert has_element?(revoked, "#shared-collection-not-found")

    edit |> element("#enable-collection-sharing") |> render_click()
    replacement_url = input_value(edit, "#collection-share-url")
    refute replacement_url == share_url

    {:ok, still_revoked, _html} = live(viewer_conn, shared_path)
    assert has_element?(still_revoked, "#shared-collection-not-found")
  end

  test "owner and shared collection pages append bounded result pages", %{conn: conn} do
    owner = viewer_user_fixture()
    viewer = viewer_user_fixture()
    owner_scope = Scope.for_user(owner)
    account = provider_account_fixture(owner)

    games =
      Enum.map(1..101, fn number ->
        game_fixture(
          account,
          "Paged game #{String.pad_leading(Integer.to_string(number), 3, "0")}"
        )
      end)

    {:ok, collection} = Collections.create_collection(owner_scope, %{name: "Paged"})

    assert {:ok, 101} =
             Collections.add_games(owner_scope, collection.id, Enum.map(games, & &1.id))

    {:ok, owner_view, _html} =
      conn |> log_in_user(owner) |> live(~p"/collections/#{collection.id}")

    assert node_count(owner_view, "#collection-games [id^='collection-game-']") == 100
    assert has_element?(owner_view, "#load-more-collection-games")
    owner_view |> element("#load-more-collection-games") |> render_click()
    assert node_count(owner_view, "#collection-games [id^='collection-game-']") == 101
    refute has_element?(owner_view, "#load-more-collection-games")

    assert {:ok, _collection} = Collections.enable_sharing(owner_scope, collection.id)
    assert {:ok, share_token} = Collections.share_token(owner_scope, collection.id)

    {:ok, shared_view, _html} =
      build_conn()
      |> log_in_user(viewer)
      |> live(~p"/collections/shared?#{%{share_token: share_token}}")

    assert node_count(
             shared_view,
             "#shared-collection-games [id^='shared-collection-game-']"
           ) == 100

    assert has_element?(shared_view, "#load-more-shared-collection-games")
    shared_view |> element("#load-more-shared-collection-games") |> render_click()

    assert node_count(
             shared_view,
             "#shared-collection-games [id^='shared-collection-game-']"
           ) == 101

    refute has_element?(shared_view, "#load-more-shared-collection-games")
  end

  defp input_value(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp current_game_order(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#collection-current-games [data-reorder-row]")
    |> Enum.map(fn row ->
      row
      |> LazyHTML.attribute("data-game-id")
      |> List.first()
      |> String.to_integer()
    end)
  end

  defp node_count(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.count()
  end

  defp provider_account_fixture(owner) do
    unique = System.unique_integer([:positive])

    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: :steam,
      external_user_id: "collection-live-account-#{unique}",
      display_name: "Collection account",
      sharing_policy: :selected_users
    })
    |> Ecto.Changeset.put_change(:owner_user_id, owner.id)
    |> Repo.insert!()
  end

  defp game_fixture(account, title) do
    unique = System.unique_integer([:positive])
    normalized_title = Iri.Library.Title.normalize(title)

    game =
      %Game{}
      |> Game.changeset(%{
        title: title,
        normalized_title: normalized_title,
        slug: "collection-live-game-#{unique}",
        release_year: 2022,
        rating: 90.0
      })
      |> Repo.insert!()

    source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: :steam,
        external_id: "collection-live-game-#{unique}",
        source_title: title,
        normalized_source_title: normalized_title,
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
