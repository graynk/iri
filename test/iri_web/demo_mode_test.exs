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

defmodule IriWeb.DemoModeTest do
  use IriWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Iri.Accounts.{Scope, User, UserToken}
  alias Iri.Collections
  alias Iri.Demo
  alias Iri.Integrations.ProviderAccount
  alias Iri.Integrations.Steam.Reconciler
  alias Iri.Library.{Game, GameSource}
  alias Iri.Repo

  setup do
    instance_mode = Application.get_env(:iri, :instance_mode)

    user =
      Repo.insert!(%User{
        username: "demo",
        hashed_password: Bcrypt.hash_pwd_salt("demo"),
        role: :admin
      })

    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "76561198000000001",
        display_name: "Demo library"
      })
      |> Ecto.Changeset.put_change(:owner_user_id, user.id)
      |> Repo.insert!()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [
               %{"appid" => 10, "name" => "Accessible Demo Game"}
             ])

    game =
      %Game{}
      |> Game.changeset(%{
        title: "Accessible Demo Game",
        normalized_title: "accessible demo game",
        slug: "accessible-demo-game"
      })
      |> Repo.insert!()

    GameSource
    |> Repo.get_by!(provider: :steam, external_id: "10")
    |> Ecto.Changeset.change(game_id: game.id)
    |> Repo.update!()

    scope = Scope.for_user(user)
    {:ok, collection} = Collections.create_collection(scope, %{name: "Demo Picks"})
    {:ok, _entries} = Collections.add_games(scope, collection.id, [game.id])

    Application.put_env(:iri, :instance_mode, :demo)
    start_supervised!(Demo)

    on_exit(fn ->
      Application.put_env(:iri, :instance_mode, instance_mode)
    end)

    %{demo_user: user, game: game, collection: collection}
  end

  test "anonymous visitors browse the snapshot without creating a session token", %{conn: conn} do
    assert Repo.aggregate(UserToken, :count) == 0

    {:ok, view, _html} = live(conn, ~p"/library")

    assert has_element?(view, "a[href='#main-content']", "Skip to main content")
    assert has_element?(view, "header nav[aria-label='Main']")
    assert has_element?(view, "#demo-mode-banner[role='status']")
    assert has_element?(view, "main#main-content[tabindex='-1']")
    assert has_element?(view, "#library-page")
    assert has_element?(view, "#bulk-edit-nav-link[href='/library/statuses']")
    refute has_element?(view, "#add-games-link")
    refute has_element?(view, "#settings-nav-link")
    refute has_element?(view, "a[href='/users/log-out']")
    assert Repo.aggregate(UserToken, :count) == 0
  end

  test "write routes redirect to the read-only library", %{conn: _conn} do
    for path <- [
          "/users/register",
          "/users/log-in",
          "/library/add",
          "/collections/new",
          "/collections/123/edit",
          "/settings/account",
          "/settings/integrations",
          "/settings/accounts",
          "/auth/steam"
        ] do
      conn = get(build_conn(), path)
      assert redirected_to(conn) == "/library"
    end
  end

  test "collections stay browsable and exportable while authoring is hidden", %{
    conn: conn,
    collection: collection
  } do
    {:ok, view, _html} = live(conn, ~p"/collections")

    assert has_element?(view, "#collections-index")
    assert has_element?(view, "#open-collection-#{collection.id}")
    refute has_element?(view, "#new-collection")
    refute has_element?(view, "#edit-collection-#{collection.id}")

    {:ok, show, _html} = live(conn, ~p"/collections/#{collection.id}")

    assert has_element?(show, "#export-collection-csv")
    assert has_element?(show, "#export-collection-txt")
    assert has_element?(show, "#export-collection-html")
    refute has_element?(show, "#edit-collection")

    for {extension, content_type} <- [
          {"csv", "text/csv"},
          {"txt", "text/plain"},
          {"zip", "application/zip"}
        ] do
      export = get(build_conn(), "/collections/#{collection.id}/export.#{extension}")

      assert export.status == 200
      assert hd(get_resp_header(export, "content-type")) =~ content_type
      assert export.resp_body != ""
    end
  end

  test "bulk workflow stays visible while persistent actions are disabled", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/library/statuses")

    assert has_element?(view, "#demo-bulk-read-only-notice")
    assert has_element?(view, "#status-filter-form")
    assert has_element?(view, "#status-filter-form label[for='status-search']", "Search")
    assert has_element?(view, "label[for='status-select-page']", "Select this page")
    assert has_element?(view, "#batch-status-actions")
    assert has_element?(view, "#batch-mark-playing[disabled]")
    assert has_element?(view, "#batch-mark-completed[disabled]")

    render_hook(view, "apply_status", %{"state" => "completed"})
    assert has_element?(view, "#flash-info", "This public demo is read-only.")
  end

  test "game editing controls retain accessible state while read-only", %{conn: conn, game: game} do
    {:ok, view, _html} = live(conn, ~p"/games/#{game.slug}")

    assert has_element?(view, "#demo-game-read-only-notice")

    assert has_element?(
             view,
             "#game-state-controls[role='group'][aria-label='Completion status']"
           )

    refute has_element?(view, "#game-state-controls [role='radio']")
    assert has_element?(view, "#mark-game-playing[disabled][aria-pressed='false']")
    assert has_element?(view, "#mark-game-completed[disabled][aria-pressed='false']")
    assert has_element?(view, "#personal-rating fieldset[disabled]")

    assert has_element?(
             view,
             "#personal-note-input[readonly][aria-label='Private note about this game']"
           )

    refute has_element?(view, "#game-log-footer")
  end
end
