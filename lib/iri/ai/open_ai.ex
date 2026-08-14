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

defmodule Iri.AI.OpenAI do
  @moduledoc "Native OpenAI Responses API adapter for optional AI catalog matching."
  @behaviour Iri.AI.Adapter

  alias Iri.AI.{DecisionSchema, MatchRequest, Prompt, Provider, ProviderError}

  @base_url "https://api.openai.com"

  @impl true
  def validate_configuration(config) do
    if config.provider == :openai and is_binary(config.api_key) and is_binary(config.model),
      do: :ok,
      else:
        {:error,
         %ProviderError{
           category: :configuration,
           message: "OpenAI matching is not fully configured.",
           retryable: false
         }}
  end

  @impl true
  def decide(%MatchRequest{} = request, config, options \\ []) do
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
      url: Provider.endpoint(config.base_url || @base_url, "/v1/responses"),
      headers: [
        {"authorization", "Bearer #{config.api_key}"},
        {"content-type", "application/json"}
      ],
      json: body
    ]

    with {:ok, response} <- Provider.request(request_options, :openai, options),
         {:ok, text} <- output_text(response.body),
         {:ok, decision} <- DecisionSchema.decode(text, request) do
      {:ok, decision}
    end
  end

  defp output_text(%{"output" => output}) when is_list(output) do
    refusal =
      Enum.find_value(output, fn item ->
        Enum.find(item["content"] || [], &(&1["type"] == "refusal"))
      end)

    cond do
      refusal ->
        {:error,
         %ProviderError{
           category: :refusal,
           message: "OpenAI declined to produce a match recommendation.",
           retryable: false
         }}

      true ->
        case Enum.find_value(output, fn item ->
               Enum.find_value(item["content"] || [], fn content ->
                 if content["type"] == "output_text", do: content["text"]
               end)
             end) do
          text when is_binary(text) -> {:ok, text}
          _text -> invalid_output()
        end
    end
  end

  defp output_text(_body), do: invalid_output()

  defp invalid_output do
    {:error,
     %ProviderError{
       category: :invalid_response,
       message: "OpenAI returned no structured decision.",
       retryable: false
     }}
  end
end
