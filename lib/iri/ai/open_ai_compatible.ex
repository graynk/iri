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

defmodule Iri.AI.OpenAICompatible do
  @moduledoc "Configurable OpenAI-style adapter for self-hosted and gateway AI endpoints."
  @behaviour Iri.AI.Adapter

  alias Iri.AI.{DecisionSchema, MatchRequest, Prompt, Provider, ProviderError}

  @impl true
  def validate_configuration(config) do
    case Iri.AI.Config.enabled(config) do
      {:ok, %{provider: :openai_compatible}} ->
        :ok

      _disabled ->
        {:error,
         %ProviderError{
           category: :configuration,
           message: "The OpenAI-compatible endpoint is not fully configured.",
           retryable: false
         }}
    end
  end

  @impl true
  def decide(%MatchRequest{} = request, config, options \\ []) do
    case config.api_style do
      :responses -> decide_responses(request, config, options)
      :chat_completions -> decide_chat(request, config, options)
    end
  end

  defp decide_chat(request, config, options) do
    body =
      %{
        "model" => config.model,
        "messages" => [
          %{"role" => "system", "content" => Prompt.system()},
          %{"role" => "user", "content" => Prompt.user(request)}
        ],
        "temperature" => 0,
        "max_tokens" => 700
      }
      |> put_output_format(config.output_format, request)

    request_options = [
      method: :post,
      url: Provider.endpoint(config.base_url, "/v1/chat/completions"),
      headers: headers(config),
      json: body
    ]

    with {:ok, response} <- Provider.request(request_options, :openai_compatible, options),
         {:ok, payload} <- chat_payload(response.body),
         {:ok, decision} <- validate_payload(payload, request) do
      {:ok, decision}
    end
  end

  defp decide_responses(request, config, options) do
    body = %{
      "model" => config.model,
      "store" => false,
      "input" => [
        %{"role" => "system", "content" => Prompt.system()},
        %{"role" => "user", "content" => Prompt.user(request)}
      ],
      "text" => %{
        "format" => %{
          "type" => "json_schema",
          "name" => "iri_match_decision",
          "strict" => true,
          "schema" => DecisionSchema.json_schema(request)
        }
      },
      "max_output_tokens" => 700
    }

    request_options = [
      method: :post,
      url: Provider.endpoint(config.base_url, "/v1/responses"),
      headers: headers(config),
      json: body
    ]

    with {:ok, response} <- Provider.request(request_options, :openai_compatible, options),
         {:ok, text} <- responses_text(response.body),
         {:ok, decision} <- DecisionSchema.decode(text, request) do
      {:ok, decision}
    end
  end

  defp put_output_format(body, :json_schema, request) do
    Map.put(body, "response_format", %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => "iri_match_decision",
        "strict" => true,
        "schema" => DecisionSchema.json_schema(request)
      }
    })
  end

  defp put_output_format(body, :json_object, _request),
    do: Map.put(body, "response_format", %{"type" => "json_object"})

  defp put_output_format(body, :llama_json_schema, request),
    do:
      Map.put(body, "response_format", %{
        "type" => "json_schema",
        "schema" => DecisionSchema.json_schema(request)
      })

  defp put_output_format(body, :vllm_structured, request),
    do: Map.put(body, "structured_outputs", %{"json" => DecisionSchema.json_schema(request)})

  defp chat_payload(%{"choices" => [%{"message" => %{"content" => content}} | _rest]})
       when is_binary(content) or is_map(content),
       do: {:ok, content}

  defp chat_payload(_body), do: invalid_output()

  defp validate_payload(payload, request) when is_map(payload),
    do: DecisionSchema.validate(payload, request)

  defp validate_payload(payload, request), do: DecisionSchema.decode(payload, request)

  defp responses_text(%{"output" => output}) when is_list(output) do
    case Enum.find_value(output, fn item ->
           Enum.find_value(item["content"] || [], fn content ->
             if content["type"] == "output_text", do: content["text"]
           end)
         end) do
      text when is_binary(text) -> {:ok, text}
      _text -> invalid_output()
    end
  end

  defp responses_text(_body), do: invalid_output()

  defp headers(config) do
    [{"content-type", "application/json"}]
    |> then(fn headers ->
      if is_binary(config.api_key),
        do: [{"authorization", "Bearer #{config.api_key}"} | headers],
        else: headers
    end)
  end

  defp invalid_output do
    {:error,
     %ProviderError{
       category: :invalid_response,
       message: "The AI endpoint returned no structured decision.",
       retryable: false
     }}
  end
end
