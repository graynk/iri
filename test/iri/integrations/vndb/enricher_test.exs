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

defmodule Iri.Integrations.VNDB.EnricherTest do
  use Iri.DataCase

  alias Iri.Integrations.ProviderAccount
  alias Iri.Integrations.GOG.Reconciler, as: GOGReconciler
  alias Iri.Integrations.Steam.Reconciler
  alias Iri.Integrations.VNDB.{ClientStub, Enricher}
  alias Iri.Library.{Game, GameSource, MediaAsset}

  test "creates and links an adult VN from an exact Steam release link" do
    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "vndb-owner",
        display_name: "VNDB owner"
      })
      |> Repo.insert!()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 702_050, "name" => "Fixture Novel"}])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "702050")

    payload = %{
      "id" => "v17",
      "title" => "Fixture Novel",
      "released" => "2020-04-01",
      "description" => "A fixture visual novel.",
      "rating" => 78.5,
      "votecount" => 120,
      "developers" => [%{"id" => "p1", "name" => "Fixture Studio"}],
      "tags" => [],
      "image" => %{
        "id" => "cv17",
        "url" => "https://t.vndb.org/cv/cv17.jpg",
        "sexual" => 1.2
      },
      "screenshots" => [
        %{
          "id" => "sf17",
          "url" => "https://t.vndb.org/sf/sf17.jpg",
          "sexual" => 0.0
        }
      ],
      "_release" => %{"id" => "r12", "has_ero" => true, "minage" => 18}
    }

    assert {:ok, %{matched_count: 1, updated_count: 1}} =
             Enricher.enrich_steam_sources([source],
               client: ClientStub,
               client_options: [matches: %{"702050" => [payload]}],
               cache_cover: fn _game_id, _options -> {:ok, :not_cached_in_test} end
             )

    game = Repo.get_by!(Game, vndb_id: "v17")
    assert game.nsfw
    assert game.release_year == 2020

    source = Repo.get!(GameSource, source.id)
    assert source.game_id == game.id
    assert source.match_method == "vndb_steam_id"
    assert source.nsfw

    assert Repo.get_by!(MediaAsset, game_id: game.id, source: "vndb", kind: "cover")

    cached_screenshot =
      Repo.get_by!(MediaAsset, game_id: game.id, source: "vndb", kind: "screenshot")
      |> MediaAsset.changeset(%{
        cache_status: "ready",
        local_path: "screenshots/vndb-fixture.jpg",
        content_hash: "fixture-hash"
      })
      |> Repo.update!()

    game
    |> Game.changeset(%{nsfw: false, nsfw_override: false})
    |> Repo.update!()

    assert {:ok, refreshed} =
             Enricher.ingest_selected_game(source, payload,
               cache_cover: fn _game_id, _options -> {:ok, :not_cached_in_test} end
             )

    refute refreshed.nsfw
    assert refreshed.nsfw_override == false
    assert Repo.get!(GameSource, source.id).nsfw

    refreshed_screenshot = Repo.get!(MediaAsset, cached_screenshot.id)
    assert refreshed_screenshot.cache_status == "ready"
    assert refreshed_screenshot.local_path == "screenshots/vndb-fixture.jpg"

    refreshed
    |> Game.changeset(%{nsfw: true, nsfw_override: true})
    |> Repo.update!()

    safe_payload =
      payload
      |> Map.put("_release", %{"has_ero" => false})
      |> Map.put("image", %{"sexual" => 0.0})

    assert {:ok, refreshed} =
             Enricher.ingest_selected_game(source, safe_payload,
               cache_cover: fn _game_id, _options -> {:ok, :not_cached_in_test} end
             )

    assert refreshed.nsfw
    assert refreshed.nsfw_override
    refute Repo.get!(GameSource, source.id).nsfw
  end

  test "creates and links an adult VN from an exact GOG product slug" do
    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :gog,
        external_user_id: "vndb-gog-owner",
        display_name: "VNDB GOG owner"
      })
      |> Repo.insert!()

    assert {:ok, _counts} =
             GOGReconciler.reconcile(account, [
               %{
                 "id" => "1181224050",
                 "title" => "Fixture Novel",
                 "url" => "/game/fixture_novel",
                 "stats" => %{}
               }
             ])

    source = Repo.get_by!(GameSource, provider: :gog, external_id: "1181224050")

    payload = %{
      "id" => "v44",
      "title" => "Fixture Novel",
      "developers" => [],
      "tags" => [%{"id" => "g23", "name" => "Sexual Content", "category" => "ero"}],
      "screenshots" => [],
      "_release" => %{"id" => "r44", "has_ero" => true}
    }

    assert {:ok, %{matched_count: 1}} =
             Enricher.enrich_sources([source],
               client: ClientStub,
               client_options: [matches: %{"fixture_novel" => [payload]}],
               cache_cover: fn _game_id, _options -> {:ok, :not_cached_in_test} end
             )

    source = Repo.get!(GameSource, source.id)
    assert source.match_method == "vndb_gog_slug"
    assert source.nsfw
    assert Repo.get!(Game, source.game_id).nsfw
  end
end
