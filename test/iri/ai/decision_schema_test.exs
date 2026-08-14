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

defmodule Iri.AI.DecisionSchemaTest do
  use ExUnit.Case, async: true

  alias Iri.AI.{DecisionSchema, MatchRequest}

  test "accepts only supplied opaque candidate keys" do
    request = request()

    assert {:ok, decision} =
             DecisionSchema.validate(
               %{
                 "action" => "match",
                 "candidate_key" => "candidate_01",
                 "search_query" => nil,
                 "confidence" => 0.97,
                 "reason" => "The title and year agree."
               },
               request
             )

    assert decision.candidate_key == "candidate_01"

    assert {:error, %{category: :invalid_response}} =
             DecisionSchema.validate(
               %{
                 "action" => "match",
                 "candidate_key" => "invented_99",
                 "search_query" => nil,
                 "confidence" => 1.0,
                 "reason" => "Invented"
               },
               request
             )
  end

  test "rejects unknown output keys and non-match candidate selections" do
    payload = %{
      "action" => "reject",
      "candidate_key" => nil,
      "search_query" => nil,
      "confidence" => 0.9,
      "reason" => "A demo",
      "catalog_id" => 123
    }

    assert {:error, %{category: :invalid_response}} = DecisionSchema.validate(payload, request())

    assert {:error, %{category: :invalid_response}} =
             DecisionSchema.validate(
               %{payload | "catalog_id" => nil, "candidate_key" => "candidate_01"},
               request()
             )
  end

  test "allows two bounded catalog searches instead of invented candidates" do
    empty_request = %MatchRequest{
      source: %{"title" => "Borderlands 2 RU"},
      candidates: [],
      search_queries: []
    }

    payload = %{
      "action" => "search",
      "candidate_key" => nil,
      "search_query" => "Borderlands 2",
      "confidence" => 0.99,
      "reason" => "RU is a regional storefront suffix."
    }

    assert {:ok, decision} = DecisionSchema.validate(payload, empty_request)
    assert decision.search_query == "Borderlands 2"

    searched_request = %{empty_request | search_queries: ["Borderlands 2"]}
    assert {:ok, _decision} = DecisionSchema.validate(payload, searched_request)

    exhausted_request = %{searched_request | search_queries: ["Borderlands 2", "Borderlands"]}

    assert {:error, error} = DecisionSchema.validate(payload, exhausted_request)
    assert error.category == :invalid_response
    assert error.message =~ "search limit"
    assert error.details["model_output"]["search_query"] == "Borderlands 2"

    exhausted_schema = DecisionSchema.json_schema(exhausted_request)
    refute "search" in exhausted_schema["properties"]["action"]["enum"]
    refute "match" in exhausted_schema["properties"]["action"]["enum"]
    assert exhausted_schema["properties"]["candidate_key"]["enum"] == [nil]
    assert exhausted_schema["properties"]["search_query"]["type"] == "null"
  end

  test "normalizes an abstention that unambiguously requests an available search" do
    request = %MatchRequest{
      source: %{"title" => "Divinity II - The Dragon Knight Saga"},
      candidates: [],
      search_queries: []
    }

    payload = %{
      "action" => "abstain",
      "candidate_key" => nil,
      "confidence" => 0.98,
      "reason" => "Search the known game title before making a final decision.",
      "search_query" => "Divinity II: The Dragon Knight Saga"
    }

    assert {:ok, decision} = DecisionSchema.validate(payload, request)
    assert decision.action == "search"
    assert decision.search_query == "Divinity II: The Dragon Knight Saga"
    assert decision.raw["action"] == "abstain"

    assert decision.raw["iri_normalized_action"] == %{
             "from" => "abstain",
             "to" => "search"
           }
  end

  test "a duplicate-query correction turn requires a new search" do
    request = %MatchRequest{
      source: %{"title" => "Divinity II - The Dragon Knight Saga"},
      candidates: [],
      search_queries: ["Divinity II: The Dragon Knight Saga"],
      search_attempts: [
        %{"query" => "Divinity II: The Dragon Knight Saga", "candidate_count" => 0}
      ],
      search_feedback: "Propose a different underlying catalog title."
    }

    schema = DecisionSchema.json_schema(request)
    assert schema["properties"]["action"]["enum"] == ["search"]
    assert schema["properties"]["candidate_key"]["enum"] == [nil]
    assert schema["properties"]["search_query"]["type"] == "string"
    assert schema["properties"]["search_query"]["minLength"] == 1
  end

  defp request do
    %MatchRequest{
      source: %{"title" => "Fixture"},
      candidates: [
        %{
          "key" => "candidate_01",
          "catalog" => "igdb",
          "external_id" => "10",
          "title" => "Fixture"
        }
      ]
    }
  end
end
