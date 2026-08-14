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

defmodule IriWeb.MediaControllerTest do
  use IriWeb.ConnCase

  alias Iri.Library.{Game, MediaAsset}
  alias Iri.Repo

  setup do
    old_root = Application.get_env(:iri, :media_root)

    root =
      Path.join(System.tmp_dir!(), "iri-media-controller-#{System.unique_integer([:positive])}")

    Application.put_env(:iri, :media_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.put_env(:iri, :media_root, old_root)
    end)

    %{root: root}
  end

  test "redirects a missing cached screenshot to its allowlisted provider URL", %{conn: conn} do
    asset = screenshot_fixture("https://images.igdb.com/igdb/image/upload/screenshot.jpg")

    conn = get(conn, ~p"/media/#{asset.id}")

    assert redirected_to(conn, 302) == asset.remote_url
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "does not redirect to a media host outside the allowlist", %{conn: conn} do
    asset = screenshot_fixture("https://example.com/screenshot.jpg")

    conn = get(conn, ~p"/media/#{asset.id}")

    assert response(conn, 404) == "Not found"
  end

  test "serves an existing cached screenshot without contacting the provider", %{
    conn: conn,
    root: root
  } do
    asset = screenshot_fixture("https://images.igdb.com/igdb/image/upload/screenshot.jpg")
    path = Path.join(root, asset.local_path)
    assert :ok = File.mkdir_p(Path.dirname(path))
    assert :ok = File.write(path, <<255, 216, 255, 217>>)

    conn = get(conn, ~p"/media/#{asset.id}")

    assert response(conn, 200) == <<255, 216, 255, 217>>

    assert get_resp_header(conn, "cache-control") == [
             "private, max-age=31536000, immutable"
           ]
  end

  defp screenshot_fixture(remote_url) do
    game =
      %Game{}
      |> Game.changeset(%{
        igdb_id: System.unique_integer([:positive]),
        title: "Media fixture",
        normalized_title: "media fixture",
        slug: "media-fixture-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    %MediaAsset{}
    |> MediaAsset.changeset(%{
      game_id: game.id,
      kind: "screenshot",
      source: "igdb",
      remote_id: "screenshot-#{System.unique_integer([:positive])}",
      remote_url: remote_url,
      local_path: "screenshots/missing.jpg",
      content_hash: "fixture-hash",
      cache_status: "ready"
    })
    |> Repo.insert!()
  end
end
