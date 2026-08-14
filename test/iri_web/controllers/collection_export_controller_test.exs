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

defmodule IriWeb.CollectionExportControllerTest do
  use IriWeb.ConnCase

  import Iri.AccountsFixtures

  alias Iri.Accounts.Scope
  alias Iri.Collections
  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{Game, GameSource, LibraryItem, MediaAsset, Personalization, Title}
  alias Iri.Media
  alias Iri.Repo
  alias IriWeb.Theme

  test "owners download CSV and text exports with comments and store links", %{conn: conn} do
    owner = viewer_user_fixture()
    scope = Scope.for_user(owner)
    game = game_fixture(owner, "=SUM(A1)")
    {:ok, collection} = Collections.create_collection(scope, %{name: "Portable picks"})
    assert {:ok, 1} = Collections.add_games(scope, collection.id, [game.id])

    assert {:ok, _entry} =
             Collections.update_entry_comment(
               scope,
               collection.id,
               game.id,
               ~s(Great, "really")
             )

    assert {:ok, _state} = Personalization.set_rating(scope, game.id, 4)
    conn = log_in_user(conn, owner)

    csv_conn = get(conn, ~p"/collections/#{collection.id}/export.csv")
    csv = response(csv_conn, 200)
    assert get_resp_header(csv_conn, "content-type") == ["text/csv; charset=utf-8"]

    assert get_resp_header(csv_conn, "content-disposition") == [
             ~s(attachment; filename="portable-picks.csv")
           ]

    assert csv =~ "Title,Release year,IGDB rating,My rating,Comment,Store links"
    assert csv =~ "'=SUM(A1)"
    assert csv =~ ~s("Great, ""really""")
    assert csv =~ "Steam: https://store.steampowered.com/app/"

    txt_conn = get(conn, ~p"/collections/#{collection.id}/export.txt")
    txt = response(txt_conn, 200)
    assert txt =~ "Portable picks"
    assert txt =~ ~s(Great, "really")
    assert txt =~ "Steam: https://store.steampowered.com/app/"
    refute txt =~ "IGDB rating"
    refute txt =~ "My rating"
    refute txt =~ "Comment:"
    refute txt =~ "87.5"
  end

  test "exports do not disclose another user's collection", %{conn: conn} do
    owner = viewer_user_fixture()
    viewer = viewer_user_fixture()
    {:ok, collection} = Collections.create_collection(Scope.for_user(owner), %{name: "Private"})

    conn = conn |> log_in_user(viewer) |> get(~p"/collections/#{collection.id}/export.csv")
    assert response(conn, 404) == "Collection not found.\n"
  end

  test "static exports embed the currently selected theme", %{conn: conn} do
    owner = viewer_user_fixture()

    {:ok, collection} =
      Collections.create_collection(Scope.for_user(owner), %{name: "Themed export"})

    conn = log_in_user(conn, owner)

    for {selected, expected, color} <- [
          {"dark", "dark", "#0f0e17"},
          {"light", "light", "#eff0f3"},
          {"vapor", "vapor", "#3f4738"},
          {"high-contrast", "high-contrast", "#000000"},
          {"ai-slop", "ai-slop", "#020617"},
          {"unknown", "dark", "#0f0e17"}
        ] do
      themed_conn =
        conn
        |> put_req_cookie(Theme.cookie_name(), selected)
        |> get(~p"/collections/#{collection.id}/export.zip")

      {:ok, extracted} = themed_conn |> response(200) |> :zip.extract([:memory])

      index =
        Enum.find_value(extracted, fn
          {~c"themed-export/index.html", contents} -> IO.iodata_to_binary(contents)
          _file -> nil
        end)

      document = LazyHTML.from_document(index)
      metadata = LazyHTML.from_fragment(index)

      assert document
             |> LazyHTML.filter(~s(html[data-theme="#{expected}"]))
             |> Enum.count() == 1

      assert [^color] =
               metadata
               |> LazyHTML.filter(~s(meta[name="theme-color"]))
               |> LazyHTML.attribute("content")

      assert metadata
             |> LazyHTML.query(
               ~s(main.shell > [data-theme-switcher] > [data-theme-toggle][aria-controls="theme-menu"][aria-expanded="false"])
             )
             |> Enum.count() == 1

      assert metadata
             |> LazyHTML.query(~s(#theme-menu[data-theme-menu][role="group"][hidden]))
             |> Enum.count() == 1

      assert metadata
             |> LazyHTML.query(~s([data-theme-option]))
             |> Enum.count() == 5

      assert metadata
             |> LazyHTML.query(~s([data-theme-option="#{expected}"][aria-pressed="true"]))
             |> Enum.count() == 1
    end
  end

  test "owners download a merge-safe static website without personal game notes", %{conn: conn} do
    owner = viewer_user_fixture()
    game = game_fixture(owner, "Portable adventure")
    account = Repo.get_by!(ProviderAccount, owner_user_id: owner.id)

    owner =
      owner
      |> Ecto.Changeset.change(steam_id: account.external_user_id)
      |> Repo.update!()

    scope = Scope.for_user(owner)
    {:ok, collection} = Collections.create_collection(scope, %{name: "Static picks"})
    assert {:ok, 1} = Collections.add_games(scope, collection.id, [game.id])

    assert {:ok, _entry} =
             Collections.update_entry_comment(
               scope,
               collection.id,
               game.id,
               "Public <script>alert('no')</script> comment"
             )

    assert {:ok, _state} = Personalization.set_rating(scope, game.id, 5)
    assert {:ok, _state} = Personalization.set_note(scope, game.id, "Private game note")

    game
    |> Game.changeset(%{summary: "A useful public summary.", nsfw: true})
    |> Repo.update!()

    Repo.get_by!(LibraryItem, provider_account_id: account.id)
    |> LibraryItem.changeset(%{playtime_minutes: 125})
    |> Repo.update!()

    family_account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "family-export-account-#{game.id}",
        display_name: "Family account",
        sharing_policy: :selected_users
      })
      |> Ecto.Changeset.put_change(:owner_user_id, owner.id)
      |> Repo.insert!()

    source = Repo.get_by!(GameSource, game_id: game.id)

    %LibraryItem{}
    |> LibraryItem.changeset(%{
      provider_account_id: family_account.id,
      game_source_id: source.id,
      playtime_minutes: 1_000
    })
    |> Repo.insert!()

    cover_contents = "cached-cover-#{game.id}"
    cover_hash = Base.encode16(:crypto.hash(:sha256, cover_contents), case: :lower)
    relative_path = "collection-export/#{cover_hash}.jpg"
    absolute_path = Path.join(Media.media_root(), relative_path)
    File.mkdir_p!(Path.dirname(absolute_path))
    File.write!(absolute_path, cover_contents)
    on_exit(fn -> File.rm(absolute_path) end)

    %MediaAsset{}
    |> MediaAsset.changeset(%{
      game_id: game.id,
      kind: "cover",
      source: "igdb",
      remote_id: "static-cover-#{game.id}",
      remote_url: "https://images.igdb.com/cover.jpg",
      local_path: relative_path,
      content_hash: cover_hash,
      cache_status: "ready"
    })
    |> Repo.insert!()

    %MediaAsset{}
    |> MediaAsset.changeset(%{
      game_id: game.id,
      kind: "screenshot",
      source: "igdb",
      remote_id: "static-screen-#{game.id}",
      remote_url: "https://images.igdb.com/screenshot.jpg",
      cache_status: "remote"
    })
    |> Repo.insert!()

    zip_conn =
      conn
      |> put_req_cookie(Theme.cookie_name(), "vapor")
      |> log_in_user(owner)
      |> get(~p"/collections/#{collection.id}/export.zip")

    archive = response(zip_conn, 200)

    assert get_resp_header(zip_conn, "content-type") == ["application/zip; charset=utf-8"]

    assert get_resp_header(zip_conn, "content-disposition") == [
             ~s(attachment; filename="static-picks.zip")
           ]

    {:ok, extracted} = :zip.extract(archive, [:memory])

    files =
      Map.new(extracted, fn {name, contents} ->
        {List.to_string(name), IO.iodata_to_binary(contents)}
      end)

    page_name = "game-#{game.slug}-#{game.id}.html"
    page_href = String.trim_trailing(page_name, ".html")
    assert Map.has_key?(files, "static-picks/service-worker.js")
    assert files["assets/covers/#{cover_hash}.jpg"] == cover_contents
    assert files["static-picks/index.html"] =~ ~s(href="#{page_href}")
    refute files["static-picks/index.html"] =~ ~s(href="#{page_name}")
    assert files["static-picks/index.html"] =~ "<style>:root{"
    assert files["static-picks/index.html"] =~ ~s(<html lang="en" data-theme="vapor">)
    assert files["static-picks/index.html"] =~ ~s(<meta name="theme-color" content="#3f4738">)
    assert files["static-picks/index.html"] =~ "--canvas:#3f4738"

    assert files["static-picks/index.html"] =~
             "--button:linear-gradient(to bottom,#5f6d56,#58654f)"

    for theme <- ~w(dark light vapor high-contrast ai-slop) do
      assert files["static-picks/index.html"] =~
               ~s(html[data-theme="#{theme}"]{color-scheme:)
    end

    refute files["static-picks/index.html"] =~ "--rating:"

    assert files["static-picks/index.html"] =~
             ".chip.rating{background:var(--accent-soft);color:var(--accent-text)}"

    assert files["static-picks/index.html"] =~
             ".comment{border-color:var(--accent);background:var(--accent-soft)"

    assert files["static-picks/index.html"] =~ "<script>(()=>{"
    assert files["static-picks/index.html"] =~ ~s(<h2 class="sr-only">Games</h2>)

    assert files["static-picks/index.html"] =~
             ~r/<a class="cover"[^>]+aria-hidden="true"><img[^>]+class="sensitive"><\/a>/

    refute files["static-picks/index.html"] =~ ~s(<script src=)
    refute files["static-picks/index.html"] =~ ~s(rel="stylesheet")
    refute files["static-picks/index.html"] =~ ~s(loading="lazy")

    assert files["static-picks/service-worker.js"] =~ "../assets/covers/#{cover_hash}.jpg"
    assert files["static-picks/service-worker.js"] =~ page_name

    assert files["static-picks/index.html"] =~
             "Public &lt;script&gt;alert(&#39;no&#39;)&lt;/script&gt; comment"

    refute files["static-picks/index.html"] =~ "<script>alert('no')</script>"

    detail = files["static-picks/#{page_name}"]
    assert detail =~ "<style>:root{"
    assert detail =~ ~s(href="./")
    refute detail =~ ~s(href="index.html")
    assert detail =~ "5/5"
    assert detail =~ "2.1h played"
    refute detail =~ "16.7h played"
    assert detail =~ "Public &lt;script&gt;alert(&#39;no&#39;)&lt;/script&gt; comment"
    assert detail =~ "A useful public summary."
    assert detail =~ "https://images.igdb.com/screenshot.jpg"
    assert detail =~ "data-lightbox-trigger"
    assert detail =~ ~s(<dialog class="lightbox" data-lightbox)
    assert detail =~ "data-lightbox-previous"
    assert detail =~ "data-lightbox-next"
    assert detail =~ "data-lightbox-status"
    assert detail =~ ~s(data-sensitive-trigger aria-label="Reveal sensitive image")
    assert detail =~ ~s(aria-pressed="false")
    assert detail =~ ~s(aria-label="Reveal Screenshot from Portable adventure")

    assert detail =~
             ~s(data-lightbox-label="Enlarge Screenshot from Portable adventure")

    refute detail =~ ~s(loading="lazy")
    assert detail =~ "https://store.steampowered.com/app/"
    refute detail =~ "Private game note"
    refute detail =~ "/games/"
  end

  defp game_fixture(owner, title) do
    unique = System.unique_integer([:positive])

    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "collection-export-account-#{unique}",
        display_name: "Export account",
        sharing_policy: :selected_users
      })
      |> Ecto.Changeset.put_change(:owner_user_id, owner.id)
      |> Repo.insert!()

    game =
      %Game{}
      |> Game.changeset(%{
        title: title,
        normalized_title: Title.normalize(title),
        slug: "collection-export-game-#{unique}",
        release_year: 2024,
        rating: 87.5
      })
      |> Repo.insert!()

    source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: :steam,
        external_id: Integer.to_string(unique),
        source_title: title,
        normalized_source_title: Title.normalize(title),
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
