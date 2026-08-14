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

defmodule Iri.Integrations.Steam.CompatibilityTest do
  use Iri.DataCase

  alias Iri.Integrations.ProviderAccount
  alias Iri.Integrations.ProtonDB.Client, as: ProtonDBClient

  alias Iri.Integrations.Steam.{
    Compatibility,
    Reconciler,
    StoreClient,
    StoreRateLimitedClientStub,
    StoreClientStub,
    StoreFailingClientStub
  }

  alias Iri.Library.{Game, GameSource, Title}

  test "caches compatibility metadata and skips fresh sources on normal refreshes" do
    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "76561198000000001",
        display_name: "Owner"
      })
      |> Repo.insert!()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 620, "name" => "Portal 2"}])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "620")

    source
    |> GameSource.changeset(%{compatibility_checked_at: DateTime.utc_now(:second)})
    |> Repo.update!()

    assert {:ok, %{discovered_count: 1, updated_count: 1, failed_count: 0}} =
             Compatibility.sync(
               client: StoreClientStub,
               client_options: [test_pid: self()],
               progress: fn details ->
                 send(self(), {:compatibility_progress, details})
                 :ok
               end,
               protondb_client_options: [test_pid: self()],
               throttle_ms: 0
             )

    assert_received {:compatibility_fetched, "620"}
    assert_received {:protondb_fetched, "620", nil}

    assert_received {:compatibility_progress, %{processed_count: 0, discovered_count: 1}}

    assert_received {:compatibility_progress,
                     %{processed_count: 1, discovered_count: 1, updated_count: 1}}

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "620")
    assert source.catalog_kind == "game"
    assert source.controller_support == "full"
    assert source.deck_compatibility == "verified"
    assert source.protondb_tier == "gold"
    assert source.protondb_etag == ~s("fixture-protondb-etag")
    assert source.protondb_checked_at
    assert source.available_windows
    refute source.available_mac
    assert source.available_linux
    assert source.vr_support == "supported"
    assert source.compatibility_checked_at

    assert {:ok, %{discovered_count: 0}} =
             Compatibility.sync(client: StoreClientStub, throttle_ms: 0)

    assert {:ok, %{discovered_count: 1, updated_count: 1}} =
             Compatibility.sync(
               client: StoreClientStub,
               protondb_client_options: [test_pid: self()],
               throttle_ms: 0,
               force: true
             )

    assert_received {:protondb_fetched, "620", ~s("fixture-protondb-etag")}
  end

  test "finishes Store and Deck checks before starting lower-priority ProtonDB checks" do
    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "phase-order-owner",
        display_name: "Owner"
      })
      |> Repo.insert!()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [
               %{"appid" => 10, "name" => "First"},
               %{"appid" => 20, "name" => "Second"}
             ])

    assert {:ok, %{discovered_count: 2, updated_count: 2}} =
             Compatibility.sync(
               client: StoreClientStub,
               client_options: [test_pid: self()],
               protondb_client_options: [test_pid: self()],
               throttle_ms: 0
             )

    assert_receive {:compatibility_fetched, "10"}
    assert_receive {:compatibility_fetched, "20"}
    assert_receive {:deck_compatibility_fetched, "10"}
    assert_receive {:deck_compatibility_fetched, "20"}
    assert_receive {:protondb_fetched, "10", nil}
    assert_receive {:protondb_fetched, "20", nil}
  end

  test "pauses for Retry-After and resumes the same Store AppID" do
    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "adaptive-rate-limit-owner",
        display_name: "Owner"
      })
      |> Repo.insert!()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 620, "name" => "Portal 2"}])

    counter = start_supervised!({Agent, fn -> 0 end})

    assert {:ok, %{updated_count: 1, failed_count: 0}} =
             Compatibility.sync(
               client: StoreRateLimitedClientStub,
               client_options: [counter: counter, test_pid: self()],
               protondb_gate: fn -> :deferred end,
               sleep: fn delay_ms -> send(self(), {:store_cooldown, delay_ms}) end,
               store_rate_limit_fallback_ms: 1_500,
               throttle_ms: 0
             )

    assert_received {:store_attempt, "620", 1}
    assert_received {:store_cooldown, 2_000}
    assert_received {:store_attempt, "620", 2}
    assert_received {:store_cooldown, 1_500}
    assert_received {:store_attempt, "620", 3}
    assert Repo.get_by!(GameSource, provider: :steam, external_id: "620").compatibility_checked_at
  end

  test "defers ProtonDB when higher-priority enrichment is waiting" do
    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "deferred-protondb-owner",
        display_name: "Owner"
      })
      |> Repo.insert!()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 620, "name" => "Portal 2"}])

    assert {:ok,
            %{
              updated_count: 1,
              steam_updated_count: 1,
              protondb_modified_count: 0,
              protondb_deferred_count: 1
            }} =
             Compatibility.sync(
               client: StoreClientStub,
               client_options: [test_pid: self()],
               protondb_client_options: [test_pid: self()],
               protondb_gate: fn ->
                 send(self(), :protondb_gate_checked)
                 :deferred
               end,
               throttle_ms: 0
             )

    assert_received {:compatibility_fetched, "620"}
    assert_received :protondb_gate_checked
    refute_received {:protondb_fetched, "620", _etag}

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "620")
    assert source.compatibility_checked_at
    refute source.protondb_checked_at

    assert {:ok, %{protondb_modified_count: 1, protondb_deferred_count: 0}} =
             Compatibility.sync(
               client: StoreClientStub,
               protondb_client_options: [test_pid: self()],
               throttle_ms: 0
             )

    assert_received {:protondb_fetched, "620", nil}
  end

  test "a ProtonDB 304 preserves the tier and ETag while refreshing its timestamp" do
    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "etag-owner",
        display_name: "Owner"
      })
      |> Repo.insert!()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 620, "name" => "Portal 2"}])

    old_checked_at = DateTime.add(DateTime.utc_now(:second), -8, :day)
    source = Repo.get_by!(GameSource, provider: :steam, external_id: "620")

    source
    |> GameSource.changeset(%{
      catalog_kind: "game",
      compatibility_checked_at: DateTime.utc_now(:second),
      protondb_tier: "gold",
      protondb_etag: ~s("current-etag"),
      protondb_checked_at: old_checked_at
    })
    |> Repo.update!()

    test_pid = self()

    request = fn options, :protondb ->
      send(test_pid, {:protondb_request, options})
      {:ok, %{status: 304, headers: %{}, body: ""}}
    end

    assert {:ok,
            %{
              discovered_count: 1,
              updated_count: 1,
              protondb_modified_count: 0,
              protondb_not_modified_count: 1
            }} =
             Compatibility.sync(
               protondb_client: ProtonDBClient,
               protondb_client_options: [request: request],
               throttle_ms: 0
             )

    assert_received {:protondb_request, options}
    assert options[:headers] == [{"if-none-match", ~s("current-etag")}]

    source = Repo.get!(GameSource, source.id)
    assert source.protondb_tier == "gold"
    assert source.protondb_etag == ~s("current-etag")
    assert DateTime.compare(source.protondb_checked_at, old_checked_at) == :gt
  end

  test "does not start another ProtonDB batch after a final rate limit" do
    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "rate-limited-owner",
        display_name: "Owner"
      })
      |> Repo.insert!()

    games = Enum.map(1..11, &%{"appid" => &1 * 10, "name" => "Game #{&1}"})
    assert {:ok, _counts} = Reconciler.reconcile(account, games)

    now = DateTime.utc_now(:second)

    from(source in GameSource, where: source.provider == :steam)
    |> Repo.update_all(set: [catalog_kind: "game", compatibility_checked_at: now])

    assert {:ok, %{discovered_count: 11, updated_count: 0, failed_count: 10}} =
             Compatibility.sync(
               protondb_client: Iri.Integrations.ProtonDB.RateLimitedClientStub,
               protondb_client_options: [test_pid: self()],
               throttle_ms: 0
             )

    assert_received {:protondb_fetched, "10"}
    refute_received {:protondb_fetched, "110"}
  end

  test "returns bounded details for item failures" do
    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "76561198000000002",
        display_name: "Owner"
      })
      |> Repo.insert!()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 620, "name" => "Portal 2"}])

    assert {:ok, %{discovered_count: 1, failed_count: 1, failures: [failure]}} =
             Compatibility.sync(client: StoreFailingClientStub, throttle_ms: 0)

    assert failure.kind == "item_failed"
    assert failure.message =~ "Portal 2"
    assert failure.message =~ "fixture store connection closed"
    assert failure.retryable
  end

  test "completes legacy apps whose Store pages are no longer available" do
    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "legacy-owner",
        display_name: "Legacy owner"
      })
      |> Repo.insert!()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 202_390, "name" => "Vessel Demo"}])

    request = fn options, _provider ->
      if String.contains?(options[:url], "appdetails") do
        {:ok, %{body: %{"202390" => %{"success" => false}}}}
      else
        {:ok, %{body: %{"success" => 1, "results" => %{"resolved_category" => 0}}}}
      end
    end

    assert {:ok, %{updated_count: 1, failed_count: 0, failures: []}} =
             Compatibility.sync(
               client: StoreClient,
               client_options: [request: request],
               throttle_ms: 0,
               force: true
             )

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "202390")
    assert source.catalog_kind == "demo"
    assert source.compatibility_checked_at
  end

  test "a store-unavailable game with a plain title is not refetched every run" do
    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "unavailable-owner",
        display_name: "Owner"
      })
      |> Repo.insert!()

    # A normal title yields no catalog_kind from the title heuristic, and the
    # Store page 404s, so the metadata comes back without a catalog_kind.
    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 999_001, "name" => "Delisted Game"}])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "999001")
    assert is_nil(source.catalog_kind)

    request = fn options, _provider ->
      if String.contains?(options[:url], "appdetails") do
        {:ok, %{body: %{"999001" => %{"success" => false}}}}
      else
        {:error, :unavailable}
      end
    end

    opts = [client: StoreClient, client_options: [request: request], throttle_ms: 0]

    assert {:ok, %{discovered_count: 1, updated_count: 1}} = Compatibility.sync(opts)

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "999001")
    assert source.catalog_kind == "unknown"
    assert source.compatibility_checked_at

    # The freshly-checked source must not be selected again on the next run.
    assert {:ok, %{discovered_count: 0}} = Compatibility.sync(opts)
  end

  test "propagates Steam NSFW metadata to an already matched game" do
    account =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: :steam,
        external_user_id: "76561198000000003",
        display_name: "Owner"
      })
      |> Repo.insert!()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 999, "name" => "Adult Fixture"}])

    game =
      %Game{}
      |> Game.changeset(%{
        title: "Adult Fixture",
        normalized_title: Title.normalize("Adult Fixture"),
        slug: "adult-fixture-999"
      })
      |> Repo.insert!()

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "999")
    source |> GameSource.changeset(%{game_id: game.id}) |> Repo.update!()

    assert {:ok, %{updated_count: 1}} =
             Compatibility.sync(
               client: StoreClientStub,
               client_options: [nsfw: true],
               throttle_ms: 0,
               force: true
             )

    assert Repo.get!(GameSource, source.id).nsfw
    assert Repo.get!(Game, game.id).nsfw

    assert {:ok, %{updated_count: 1}} =
             Compatibility.sync(
               client: StoreClientStub,
               client_options: [nsfw: false],
               throttle_ms: 0,
               force: true
             )

    refute Repo.get!(GameSource, source.id).nsfw
    refute Repo.get!(Game, game.id).nsfw
  end
end
