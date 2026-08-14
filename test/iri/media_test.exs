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

defmodule Iri.MediaTest do
  use Iri.DataCase

  alias Iri.Library.{Game, MediaAsset}
  alias Iri.Media

  setup do
    old_root = Application.get_env(:iri, :media_root)
    root = Path.join(System.tmp_dir!(), "iri-media-#{System.unique_integer([:positive])}")
    Application.put_env(:iri, :media_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.put_env(:iri, :media_root, old_root)
    end)

    %{root: root}
  end

  test "caches an allowlisted IGDB cover with content validation", %{root: root} do
    game = game_fixture()
    asset = cover_fixture(game)

    request = fn _options, :igdb ->
      {:ok,
       %Req.Response{
         status: 200,
         headers: %{"content-type" => ["image/jpeg"]},
         body: <<255, 216, 255, 217>>
       }}
    end

    assert {:ok, cached} = Media.cache_cover(game.id, request: request)
    assert cached.cache_status == "ready"
    assert cached.content_hash
    assert File.regular?(Path.join(root, cached.local_path))
    assert {:ok, ^cached, _path} = Media.get_cached_asset(asset.id)
  end

  test "rejects a non-IGDB media host" do
    game = game_fixture()

    %MediaAsset{}
    |> MediaAsset.changeset(%{
      game_id: game.id,
      kind: "cover",
      source: "igdb",
      remote_id: "evil",
      remote_url: "https://example.com/cover.jpg",
      cache_status: "remote"
    })
    |> Repo.insert!()

    assert {:error, :disallowed_media_url} = Media.cache_cover(game.id)
  end

  test "caches remote and previously failed screenshots in the screenshot directory", %{
    root: root
  } do
    game = game_fixture()

    remote = screenshot_fixture(game, "remote", "remote")
    failed = screenshot_fixture(game, "failed", "failed")

    request = fn _options, :igdb ->
      {:ok,
       %Req.Response{
         status: 200,
         headers: %{"content-type" => ["image/jpeg"]},
         body: <<255, 216, 1, 2, 255, 217>>
       }}
    end

    assert {:ok, %{cached: 2, failed: 0, failures: []}} =
             Media.cache_screenshots(request: request)

    for asset <- [remote, failed] do
      cached = Repo.get!(MediaAsset, asset.id)
      assert cached.cache_status == "ready"
      assert String.starts_with?(cached.local_path, "screenshots/")
      assert File.regular?(Path.join(root, cached.local_path))
    end
  end

  test "records one screenshot failure without preventing other screenshots from caching" do
    game = game_fixture()
    cached_asset = screenshot_fixture(game, "cache-me", "remote")

    rejected_asset =
      %MediaAsset{}
      |> MediaAsset.changeset(%{
        game_id: game.id,
        kind: "screenshot",
        source: "igdb",
        remote_id: "rejected",
        remote_url: "https://example.com/rejected.jpg",
        cache_status: "remote"
      })
      |> Repo.insert!()

    request = fn _options, :igdb ->
      {:ok,
       %Req.Response{
         status: 200,
         headers: %{"content-type" => ["image/jpeg"]},
         body: <<255, 216, 255, 217>>
       }}
    end

    assert {:ok, %{cached: 1, failed: 1, failures: [failure]}} =
             Media.cache_screenshots(request: request)

    assert failure.asset_id == rejected_asset.id
    assert Repo.get!(MediaAsset, cached_asset.id).cache_status == "ready"
    assert Repo.get!(MediaAsset, rejected_asset.id).cache_status == "failed"
  end

  test "prunes orphaned files and repairs missing entries without evicting cached covers", %{
    root: root
  } do
    game = game_fixture()
    assert :ok = File.mkdir_p(Path.join(root, "covers"))
    assert :ok = File.write(Path.join(root, "covers/owned.jpg"), <<1, 2, 3, 4>>)
    assert :ok = File.write(Path.join(root, "covers/orphan.jpg"), <<5, 6>>)

    owned =
      %MediaAsset{}
      |> MediaAsset.changeset(%{
        game_id: game.id,
        kind: "cover",
        source: "igdb",
        remote_id: "owned",
        remote_url: "https://images.igdb.com/igdb/image/upload/t_cover_big_2x/owned.jpg",
        local_path: "covers/owned.jpg",
        cache_status: "ready"
      })
      |> Repo.insert!()

    missing =
      %MediaAsset{}
      |> MediaAsset.changeset(%{
        game_id: game.id,
        kind: "screenshot",
        source: "igdb",
        remote_id: "missing",
        remote_url: "https://images.igdb.com/igdb/image/upload/t_screenshot_big/missing.jpg",
        local_path: "covers/missing.jpg",
        cache_status: "ready"
      })
      |> Repo.insert!()

    assert {:ok, counts} = Media.maintain_cache()
    assert counts.orphaned_files_pruned == 1
    assert counts.missing_assets_reset == 1
    refute File.exists?(Path.join(root, "covers/orphan.jpg"))
    assert File.exists?(Path.join(root, "covers/owned.jpg"))
    assert Repo.get!(MediaAsset, owned.id).cache_status == "ready"
    assert Repo.get!(MediaAsset, missing.id).cache_status == "remote"
  end

  defp game_fixture do
    %Game{}
    |> Game.changeset(%{
      igdb_id: System.unique_integer([:positive]),
      title: "Fixture",
      normalized_title: "fixture",
      slug: "fixture-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp cover_fixture(game) do
    %MediaAsset{}
    |> MediaAsset.changeset(%{
      game_id: game.id,
      kind: "cover",
      source: "igdb",
      remote_id: "co-fixture",
      remote_url: "https://images.igdb.com/igdb/image/upload/t_cover_big_2x/co-fixture.jpg",
      cache_status: "remote"
    })
    |> Repo.insert!()
  end

  defp screenshot_fixture(game, remote_id, cache_status) do
    %MediaAsset{}
    |> MediaAsset.changeset(%{
      game_id: game.id,
      kind: "screenshot",
      source: "igdb",
      remote_id: remote_id,
      remote_url: "https://images.igdb.com/igdb/image/upload/t_screenshot_big/#{remote_id}.jpg",
      cache_status: cache_status
    })
    |> Repo.insert!()
  end
end
