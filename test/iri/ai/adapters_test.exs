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

defmodule Iri.AI.AdaptersTest do
  use ExUnit.Case, async: true

  alias Iri.AI.{Anthropic, Config, MatchRequest, OpenAI, OpenAICompatible}

  test "OpenAI uses Responses strict output without storing the response" do
    request_fn = fn options ->
      send(self(), {:request, options})

      {:ok,
       %Req.Response{
         status: 200,
         headers: %{"x-request-id" => ["req-openai"]},
         body: %{
           "id" => "resp_1",
           "model" => "fixture-actual",
           "usage" => %{"input_tokens" => 100, "output_tokens" => 20},
           "output" => [
             %{
               "type" => "message",
               "content" => [
                 %{"type" => "output_text", "text" => Jason.encode!(decision_payload())}
               ]
             }
           ]
         }
       }}
    end

    config =
      Config.from_options(%{provider: :openai, api_key: "secret", model: "fixture-model"})

    assert {:ok, decision} = OpenAI.decide(request(), config, request: request_fn)
    assert decision.candidate_key == "candidate_01"

    assert_received {:request, options}
    assert options[:url] == "https://api.openai.com/v1/responses"
    assert options[:json]["store"] == false
    assert get_in(options, [:json, "text", "format", "strict"]) == true
    assert options[:receive_timeout] == 60_000
    assert headers(options)["authorization"] == "Bearer secret"
  end

  test "Anthropic forces one strict decision tool" do
    request_fn = fn options ->
      send(self(), {:request, options})

      {:ok,
       %Req.Response{
         status: 200,
         headers: %{"request-id" => ["req-anthropic"]},
         body: %{
           "model" => "claude-fixture-actual",
           "usage" => %{"input_tokens" => 80, "output_tokens" => 15},
           "content" => [
             %{
               "type" => "tool_use",
               "name" => "submit_match_decision",
               "input" => decision_payload()
             }
           ]
         }
       }}
    end

    config =
      Config.from_options(%{provider: :anthropic, api_key: "secret", model: "claude-fixture"})

    assert {:ok, decision} = Anthropic.decide(request(), config, request: request_fn)
    assert decision.action == "match"

    assert_received {:request, options}
    assert options[:url] == "https://api.anthropic.com/v1/messages"
    assert get_in(options, [:json, "tools", Access.at(0), "strict"]) == true
    assert options[:json]["tool_choice"]["name"] == "submit_match_decision"
    assert headers(options)["x-api-key"] == "secret"
  end

  test "compatible Chat Completions supports tokenless self-hosting and local validation" do
    request_fn = fn options ->
      send(self(), {:request, options})

      {:ok,
       %Req.Response{
         status: 200,
         headers: %{},
         body: %{
           "model" => "qwen-fixture",
           "choices" => [%{"message" => %{"content" => Jason.encode!(decision_payload())}}],
           "usage" => %{"prompt_tokens" => 70, "completion_tokens" => 12}
         }
       }}
    end

    config =
      Config.from_options(%{
        provider: :openai_compatible,
        model: "qwen-fixture",
        base_url: "http://ollama:11434/v1",
        output_format: :json_object
      })

    assert {:ok, decision} =
             OpenAICompatible.decide(request(), config, request: request_fn)

    assert decision.action == "match"
    assert_received {:request, options}
    assert options[:url] == "http://ollama:11434/v1/chat/completions"
    refute Map.has_key?(headers(options), "authorization")
    assert options[:json]["response_format"] == %{"type" => "json_object"}
  end

  test "compatible endpoints cannot smuggle prose or unknown candidates" do
    request_fn = fn _options ->
      {:ok,
       %Req.Response{
         status: 200,
         headers: %{"x-request-id" => ["req-invalid-output"]},
         body: %{"choices" => [%{"message" => %{"content" => "I choose candidate_01"}}]}
       }}
    end

    config =
      Config.from_options(%{
        provider: :openai_compatible,
        model: "fixture",
        base_url: "http://localhost:11434/v1"
      })

    assert {:error, error} =
             OpenAICompatible.decide(request(), config, request: request_fn)

    assert error.category == :invalid_response
    refute error.retryable
    assert error.details["model_output_text"] == "I choose candidate_01"
  end

  test "compatible endpoints support common self-hosted structured-output dialects" do
    expectations = [
      {:json_schema,
       {"response_format",
        %{
          "type" => "json_schema",
          "json_schema" => %{
            "name" => "iri_match_decision",
            "strict" => true,
            "schema" => :schema
          }
        }}},
      {:llama_json_schema, {"response_format", %{"type" => "json_schema", "schema" => :schema}}},
      {:vllm_structured, {"structured_outputs", %{"json" => :schema}}}
    ]

    for {format, {field, expected}} <- expectations do
      request_fn = fn options ->
        send(self(), {:request, format, options})

        {:ok,
         %Req.Response{
           status: 200,
           headers: %{},
           body: %{
             "model" => "local-fixture",
             "choices" => [%{"message" => %{"content" => Jason.encode!(decision_payload())}}]
           }
         }}
      end

      config =
        Config.from_options(%{
          provider: :openai_compatible,
          model: "local-fixture",
          base_url: "http://model-server:8000/v1",
          output_format: format
        })

      assert {:ok, _decision} =
               OpenAICompatible.decide(request(), config, request: request_fn)

      assert_received {:request, ^format, options}
      actual = options[:json][field]
      assert_schema_shape(actual, expected)
    end
  end

  defp request do
    %MatchRequest{
      source: %{"provider" => "steam", "external_id" => "10", "title" => "Fixture™"},
      candidates: [
        %{
          "key" => "candidate_01",
          "catalog" => "igdb",
          "external_id" => "20",
          "title" => "Fixture",
          "release_year" => 2020
        }
      ]
    }
  end

  defp decision_payload do
    %{
      "action" => "match",
      "candidate_key" => "candidate_01",
      "search_query" => nil,
      "confidence" => 0.99,
      "reason" => "The normalized title and year match."
    }
  end

  defp headers(options), do: options[:headers] |> Map.new()

  defp assert_schema_shape(actual, expected) do
    expected = replace_schema_marker(expected, schema_from(actual))
    assert actual == expected
  end

  defp schema_from(%{"json_schema" => %{"schema" => schema}}), do: schema
  defp schema_from(%{"schema" => schema}), do: schema
  defp schema_from(%{"json" => schema}), do: schema

  defp replace_schema_marker(value, schema) when is_map(value) do
    Map.new(value, fn
      {key, :schema} -> {key, schema}
      {key, nested} -> {key, replace_schema_marker(nested, schema)}
    end)
  end

  defp replace_schema_marker(value, _schema), do: value
end
