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

defmodule Iri.Integrations.IGDB.EnricherTest do
  use Iri.DataCase

  alias Iri.Integrations.IGDB.{
    ClientStub,
    Enricher,
    PartialFailureClientStub,
    TitleFallbackClientStub
  }

  alias Iri.Integrations.GOG.ClientStub, as: GOGClientStub
  alias Iri.Integrations.GOG.Reconciler, as: GOGReconciler
  alias Iri.Integrations.ProviderAccount
  alias Iri.Integrations.Steam.Reconciler
  alias Iri.Library.{Game, GameCompany, GameSource, MediaAsset, TaxonomyTerm}

  test "exact Steam AppID matches create canonical metadata idempotently" do
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [
               %{"appid" => 10, "name" => "Counter-Strike"},
               %{"appid" => 20, "name" => "Team Fortress Classic"}
             ])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "10")
    source |> GameSource.changeset(%{nsfw: true}) |> Repo.update!()

    credentials = %{"steam_source_id" => 1, "client_id" => "id", "access_token" => "token"}
    options = [client: ClientStub, cache_cover: fn _game_id, _options -> {:ok, :no_cover} end]

    assert {:ok,
            %{
              source_ids: source_ids,
              matched_count: 2,
              unmatched_count: 0,
              updated_count: 2
            }} =
             Enricher.enrich(credentials, options)

    assert Enum.sort(source_ids) ==
             GameSource
             |> Repo.all()
             |> Enum.map(& &1.id)
             |> Enum.sort()

    assert Repo.aggregate(Game, :count) == 2
    assert Repo.aggregate(TaxonomyTerm, :count) == 4
    assert Repo.aggregate(GameCompany, :count) == 2
    assert Repo.aggregate(MediaAsset, :count) == 2

    assert Repo.all(from asset in MediaAsset, select: asset.remote_id) == [
             "co-shared",
             "co-shared"
           ]

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "10") |> Repo.preload(:game)
    assert source.game_id
    assert source.game.nsfw
    assert source.match_method == "external_id"
    assert source.game.time_to_beat_main_seconds == 18_000
    assert source.game.time_to_beat_extra_seconds == 46_800

    assert {:ok, %{discovered_count: 0, matched_count: 0, updated_count: 0}} =
             Enricher.enrich(%{}, options)

    assert {:ok, %{discovered_count: 2, matched_count: 2, updated_count: 2}} =
             Enricher.enrich(credentials, Keyword.put(options, :force, true))

    assert Repo.aggregate(Game, :count) == 2
    assert Repo.aggregate(TaxonomyTerm, :count) == 4
    assert Repo.aggregate(GameCompany, :count) == 2
    assert Repo.aggregate(MediaAsset, :count) == 2
  end

  test "auto-matches one identical normalized PC title without manual review" do
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 99, "name" => "Mystery Game"}])

    credentials = %{"steam_source_id" => 1, "client_id" => "id", "access_token" => "token"}

    assert {:ok, %{matched_count: 1, unmatched_count: 0}} =
             Enricher.enrich(credentials,
               client: TitleFallbackClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "99")
    assert source.game_id
    assert source.match_method == "title_exact_pc"
  end

  test "marks directly matched IGDB erotic-theme games as NSFW" do
    assert {:ok, game} =
             Enricher.ingest_selected_game(%{
               "id" => 81_042,
               "name" => "Adult Fixture",
               "themes" => [%{"id" => 42, "name" => "Erotic", "slug" => "erotic"}],
               "screenshots" => [],
               "videos" => [],
               "involved_companies" => []
             })

    assert game.nsfw
  end

  test "backfills existing screenshot rows when screenshot downloads are enabled" do
    old_root = Application.get_env(:iri, :media_root)

    root =
      Path.join(System.tmp_dir!(), "iri-enricher-media-#{System.unique_integer([:positive])}")

    Application.put_env(:iri, :media_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.put_env(:iri, :media_root, old_root)
    end)

    game =
      %Game{}
      |> Game.changeset(%{
        igdb_id: 91_042,
        title: "Existing fixture",
        normalized_title: "existing fixture",
        slug: "existing-fixture"
      })
      |> Repo.insert!()

    screenshot =
      %MediaAsset{}
      |> MediaAsset.changeset(%{
        game_id: game.id,
        kind: "screenshot",
        source: "igdb",
        remote_id: "existing-screenshot",
        remote_url:
          "https://images.igdb.com/igdb/image/upload/t_screenshot_big/existing-screenshot.jpg",
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

    assert {:ok,
            %{
              discovered_count: 0,
              screenshots_cached_count: 1,
              screenshots_failed_count: 0
            }} =
             Enricher.enrich(%{},
               download_screenshots: true,
               media_options: [request: request]
             )

    cached = Repo.get!(MediaAsset, screenshot.id)
    assert cached.cache_status == "ready"
    assert File.regular?(Path.join(root, cached.local_path))
  end

  test "commits exact mappings when a later fallback lookup loses its connection" do
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [
               %{"appid" => 10, "name" => "Exact game"},
               %{"appid" => 99, "name" => "Unavailable lookup"}
             ])

    credentials = %{"steam_source_id" => 1, "client_id" => "id", "access_token" => "token"}

    assert {:ok,
            %{
              matched_count: 1,
              unmatched_count: 1,
              updated_count: 1,
              failed_count: 1,
              failures: [failure]
            }} =
             Enricher.enrich(credentials,
               client: PartialFailureClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    assert failure.kind == "lookup_failed"
    assert failure.message =~ "Unavailable lookup"
    assert failure.message =~ "fixture connection closed"

    exact = Repo.get_by!(GameSource, provider: :steam, external_id: "10")
    assert exact.game_id
    assert exact.match_method == "external_id"

    unavailable = Repo.get_by!(GameSource, provider: :steam, external_id: "99")
    refute unavailable.game_id
    assert unavailable.match_method == "lookup_failed"
  end

  test "ingests a library larger than one bounded database batch" do
    account = steam_account_fixture()

    games =
      Enum.map(1..55, fn appid ->
        %{"appid" => appid, "name" => "Fixture #{appid}"}
      end)

    assert {:ok, _counts} = Reconciler.reconcile(account, games)

    credentials = %{"steam_source_id" => 1, "client_id" => "id", "access_token" => "token"}

    assert {:ok, %{matched_count: 55, updated_count: 55, failed_count: 0}} =
             Enricher.enrich(credentials,
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    assert Repo.aggregate(Game, :count) == 55

    assert Repo.aggregate(
             from(source in GameSource, where: not is_nil(source.game_id)),
             :count
           ) == 55
  end

  test "merges Steam and GOG ownership when both external IDs map to one IGDB game" do
    steam_account = steam_account_fixture()
    gog_account = gog_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(steam_account, [%{"appid" => 10, "name" => "Shared Fixture"}])

    assert {:ok, gog_games} = GOGClientStub.fetch_library(gog_account, %{}, [])
    assert {:ok, _counts} = GOGReconciler.reconcile(gog_account, Enum.take(gog_games, 1))

    credentials = %{
      "steam_source_id" => 1,
      "gog_source_id" => 5,
      "client_id" => "id",
      "access_token" => "token"
    }

    assert {:ok, %{matched_count: 2, updated_count: 1}} =
             Enricher.enrich(credentials,
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    steam_source = Repo.get_by!(GameSource, provider: :steam, external_id: "10")
    gog_source = Repo.get_by!(GameSource, provider: :gog, external_id: "10")
    assert steam_source.game_id == gog_source.game_id
    assert Repo.aggregate(Game, :count) == 1
  end

  test "scopes enrichment to one library and reuses canonical metadata already stored locally" do
    steam_account = steam_account_fixture()
    gog_account = gog_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(steam_account, [%{"appid" => 10, "name" => "Shared Fixture"}])

    assert {:ok, gog_games} = GOGClientStub.fetch_library(gog_account, %{}, [])
    assert {:ok, _counts} = GOGReconciler.reconcile(gog_account, Enum.take(gog_games, 1))

    options = [client: ClientStub, cache_cover: fn _game_id, _options -> {:ok, :no_cover} end]

    assert {:ok, %{discovered_count: 1, updated_count: 1}} =
             Enricher.enrich(
               %{"steam_source_id" => 1},
               Keyword.put(options, :provider_account_id, steam_account.id)
             )

    refute Repo.get_by!(GameSource, provider: :gog, external_id: "10").game_id

    assert {:ok, %{discovered_count: 1, matched_count: 1, updated_count: 0}} =
             Enricher.enrich(
               %{"gog_source_id" => 5},
               Keyword.put(options, :provider_account_id, gog_account.id)
             )

    steam_source = Repo.get_by!(GameSource, provider: :steam, external_id: "10")
    gog_source = Repo.get_by!(GameSource, provider: :gog, external_id: "10")
    assert gog_source.game_id == steam_source.game_id
    assert Repo.aggregate(Game, :count) == 1
  end

  defp steam_account_fixture do
    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: :steam,
      external_user_id: "76561198000000001",
      display_name: "Owner"
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
end
