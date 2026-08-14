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

defmodule Iri.Integrations.Steam.StoreClientTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.Steam.StoreClient

  test "fetches the title and catalog kind needed for a manual AppID import" do
    request = fn _options, :steam ->
      {:ok,
       %{
         body: %{
           "2771670" => %{
             "success" => true,
             "data" => %{
               "steam_appid" => 2_771_670,
               "type" => "game",
               "name" => "Psychopomp",
               "is_free" => true
             }
           }
         }
       }}
    end

    assert {:ok, details} = StoreClient.fetch_app_details("2771670", request: request)
    assert details.title == "Psychopomp"
    assert details.catalog_kind == "game"
    assert details.source_url == "https://store.steampowered.com/app/2771670"
    assert details.metadata_snapshot["is_free"]
  end

  test "combines Store and Deck compatibility metadata" do
    request = fn options, provider ->
      send(self(), {:request, provider, options})

      cond do
        String.contains?(options[:url], "appdetails") ->
          {:ok,
           %{
             body: %{
               "620" => %{
                 "success" => true,
                 "data" => %{
                   "type" => "game",
                   "name" => "Portal 2",
                   "controller_support" => "full",
                   "platforms" => %{"windows" => true, "mac" => false, "linux" => true},
                   "categories" => [%{"description" => "VR Supported"}]
                 }
               }
             }
           }}

        String.contains?(options[:url], "ajaxgetdeck") ->
          {:ok, %{body: %{"success" => 1, "results" => %{"resolved_category" => 3}}}}
      end
    end

    assert {:ok, metadata} = StoreClient.fetch_metadata("620", request: request)

    assert metadata == %{
             catalog_kind: "game",
             nsfw: false,
             controller_support: "full",
             deck_compatibility: "verified",
             available_windows: true,
             available_mac: false,
             available_linux: true,
             vr_support: "supported"
           }

    assert_received {:request, :steam, options}
    assert options[:params][:appids] == "620"
    assert_received {:request, :steam, _options}
  end

  test "keeps required store metadata when optional compatibility services fail" do
    request = fn options, _provider ->
      if String.contains?(options[:url], "appdetails") do
        {:ok,
         %{
           body: %{
             "10" => %{
               "success" => true,
               "data" => %{"platforms" => %{}, "categories" => []}
             }
           }
         }}
      else
        {:error, :unavailable}
      end
    end

    assert {:ok, metadata} = StoreClient.fetch_metadata("10", request: request)
    assert metadata.controller_support == "none"
    assert metadata.deck_compatibility == "unknown"
    assert metadata.vr_support == "none"
  end

  test "treats explicitly unavailable legacy Store metadata as a completed check" do
    request = fn options, provider ->
      send(self(), {:request, provider, options})

      cond do
        String.contains?(options[:url], "appdetails") ->
          {:ok, %{body: %{"263280" => %{"success" => false}}}}

        String.contains?(options[:url], "ajaxgetdeck") ->
          {:ok, %{body: %{"success" => 1, "results" => %{"resolved_category" => 2}}}}
      end
    end

    assert {:ok, metadata} = StoreClient.fetch_metadata("263280", request: request)

    assert metadata == %{
             deck_compatibility: "playable"
           }

    refute Map.has_key?(metadata, :catalog_kind)
    assert_received {:request, :steam, store_options}
    assert store_options[:url] =~ "appdetails"
    assert_received {:request, :steam, deck_options}
    assert deck_options[:url] =~ "ajaxgetdeck"
  end

  test "accepts the Deck endpoint's keyword-list results shape" do
    request = fn options, _provider ->
      cond do
        String.contains?(options[:url], "appdetails") ->
          {:ok,
           %{
             body: %{
               "10" => %{
                 "success" => true,
                 "data" => %{"platforms" => %{}, "categories" => []}
               }
             }
           }}

        String.contains?(options[:url], "ajaxgetdeck") ->
          {:ok, %{body: %{"success" => 1, "results" => [resolved_category: 2]}}}

        true ->
          {:error, :unavailable}
      end
    end

    assert {:ok, %{deck_compatibility: "playable"}} =
             StoreClient.fetch_metadata("10", request: request)
  end

  test "classifies Steam demos, videos, playtests, and utility software as non-games" do
    for {data, expected_kind} <- [
          {%{"type" => "demo", "name" => "A Demo"}, "demo"},
          {%{"type" => "video", "name" => "A Movie"}, "video"},
          {%{"type" => "game", "name" => "Shooter Playtest"}, "playtest"},
          {%{"type" => "game", "name" => "Beta, Public Test"}, "playtest"},
          {%{"type" => "game", "name" => "Multiplayer Beta"}, "playtest"},
          {%{
             "type" => "game",
             "name" => "OVR Toolkit",
             "genres" => [%{"description" => "Utilities"}]
           }, "software"}
        ] do
      request = fn options, _provider ->
        cond do
          String.contains?(options[:url], "appdetails") ->
            {:ok,
             %{
               body: %{
                 "10" => %{
                   "success" => true,
                   "data" => Map.merge(%{"platforms" => %{}, "categories" => []}, data)
                 }
               }
             }}

          true ->
            {:error, :unavailable}
        end
      end

      assert {:ok, %{catalog_kind: ^expected_kind}} =
               StoreClient.fetch_metadata("10", request: request)
    end
  end

  test "does not treat a generic Steam sexual-content warning as a primary adult theme" do
    request = fn options, _provider ->
      if String.contains?(options[:url], "appdetails") do
        {:ok,
         %{
           body: %{
             "10" => %{
               "success" => true,
               "data" => %{
                 "type" => "game",
                 "name" => "Fixture",
                 "platforms" => %{},
                 "categories" => [],
                 "genres" => [%{"description" => "Sexual Content"}]
               }
             }
           }
         }}
      else
        {:error, :unavailable}
      end
    end

    assert {:ok, %{nsfw: false}} = StoreClient.fetch_metadata("10", request: request)
  end

  test "recognizes an explicit Steam adult genre without relying on IGDB" do
    request = fn options, _provider ->
      if String.contains?(options[:url], "appdetails") do
        {:ok,
         %{
           body: %{
             "10" => %{
               "success" => true,
               "data" => %{
                 "type" => "game",
                 "name" => "Fixture",
                 "platforms" => %{},
                 "categories" => [],
                 "genres" => [%{"description" => "Adult Only"}]
               }
             }
           }
         }}
      else
        {:error, :unavailable}
      end
    end

    assert {:ok, %{nsfw: true}} = StoreClient.fetch_metadata("10", request: request)
  end
end
