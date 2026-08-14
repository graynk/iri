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

defmodule Iri.AI.Anthropic do
  @moduledoc "Native Anthropic Messages API adapter for optional AI catalog matching."
  @behaviour Iri.AI.Adapter

  alias Iri.AI.{DecisionSchema, MatchRequest, Prompt, Provider, ProviderError}

  @base_url "https://api.anthropic.com"
  @tool_name "submit_match_decision"

  @impl true
  def validate_configuration(config) do
    if config.provider == :anthropic and is_binary(config.api_key) and is_binary(config.model),
      do: :ok,
      else:
        {:error,
         %ProviderError{
           category: :configuration,
           message: "Anthropic matching is not fully configured.",
           retryable: false
         }}
  end

  @impl true
  def decide(%MatchRequest{} = request, config, options \\ []) do
    body = %{
      "model" => config.model,
      "max_tokens" => 700,
      "system" => Prompt.system(),
      "messages" => [%{"role" => "user", "content" => Prompt.user(request)}],
      "tools" => [
        %{
          "name" => @tool_name,
          "description" => "Submit the single Iri source-to-catalog decision.",
          "strict" => true,
          "input_schema" => DecisionSchema.json_schema(request)
        }
      ],
      "tool_choice" => %{
        "type" => "tool",
        "name" => @tool_name,
        "disable_parallel_tool_use" => true
      }
    }

    request_options = [
      method: :post,
      url: Provider.endpoint(config.base_url || @base_url, "/v1/messages"),
      headers: [
        {"x-api-key", config.api_key},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ],
      json: body
    ]

    with {:ok, response} <- Provider.request(request_options, :anthropic, options),
         {:ok, payload} <- tool_payload(response.body),
         {:ok, decision} <- DecisionSchema.validate(payload, request) do
      {:ok, decision}
    end
  end

  defp tool_payload(%{"content" => content}) when is_list(content) do
    tools = Enum.filter(content, &(&1["type"] == "tool_use" and &1["name"] == @tool_name))

    case tools do
      [%{"input" => input}] when is_map(input) -> {:ok, input}
      _tools -> invalid_output()
    end
  end

  defp tool_payload(_body), do: invalid_output()

  defp invalid_output do
    {:error,
     %ProviderError{
       category: :invalid_response,
       message: "Anthropic returned no single structured decision.",
       retryable: false
     }}
  end
end
