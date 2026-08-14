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

defmodule Iri.AI.DecisionSchema do
  @moduledoc "Structured-output schema and local validation for model match decisions."

  alias Iri.AI.{MatchDecision, MatchRequest, ProviderError}
  alias Iri.Security.Redactor

  @actions ~w(match search reject keep_store_only abstain)

  @doc "Builds the provider-facing JSON Schema, constrained to the current request's candidate keys."
  def json_schema(request \\ nil) do
    actions = allowed_actions(request)
    candidate_keys = candidate_keys(request)

    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => actions},
        "candidate_key" =>
          %{"type" => ["string", "null"]}
          |> maybe_put_enum(candidate_keys),
        "search_query" => search_query_schema(request),
        "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
        "reason" => %{"type" => "string"}
      },
      "required" => [
        "action",
        "candidate_key",
        "search_query",
        "confidence",
        "reason"
      ],
      "additionalProperties" => false
    }
  end

  @doc "Validates a decoded provider payload and normalizes a permitted legacy search response."
  def validate(payload, %MatchRequest{} = request) when is_map(payload) do
    model_action = payload["action"]
    candidate_key = payload["candidate_key"]
    search_query = payload["search_query"]
    confidence = payload["confidence"]
    reason = payload["reason"]
    action = normalized_action(model_action, candidate_key, search_query, request)

    validation_error =
      cond do
        not exact_fields?(payload) ->
          "Model output contained missing or unexpected fields."

        model_action not in @actions ->
          "Model output used an unknown action."

        error = selection_error(action, candidate_key, search_query, request) ->
          error

        not (is_number(confidence) and confidence >= 0 and confidence <= 1) ->
          "Model confidence must be a number between 0 and 1."

        not (is_binary(reason) and String.trim(reason) != "") ->
          "Model output did not include a reason."

        true ->
          nil
      end

    if is_nil(validation_error) do
      raw =
        payload
        |> Map.take(~w(action candidate_key search_query confidence reason))
        |> maybe_note_normalized_action(model_action, action)

      {:ok,
       %MatchDecision{
         action: action,
         candidate_key: candidate_key,
         search_query: normalized_search_query(search_query),
         confidence: confidence / 1,
         reason: reason |> String.trim() |> String.slice(0, 500),
         raw: raw
       }}
    else
      {:error, invalid_response(validation_error, %{"model_output" => diagnostic(payload)})}
    end
  end

  def validate(_payload, _request),
    do: {:error, invalid_response("Model output was not a JSON object.")}

  @doc "Decodes and validates a provider's JSON text response."
  def decode(text, request) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, payload} ->
        validate(payload, request)

      {:error, _reason} ->
        {:error,
         invalid_response("Model output was not valid JSON.", %{
           "model_output_text" => diagnostic(text)
         })}
    end
  end

  def decode(_text, _request),
    do: {:error, invalid_response("Model response did not contain text output.")}

  defp exact_fields?(payload) do
    MapSet.equal?(
      MapSet.new(Map.keys(payload)),
      MapSet.new(~w(action candidate_key search_query confidence reason))
    )
  end

  defp allowed_actions(nil), do: @actions

  defp allowed_actions(%MatchRequest{search_feedback: feedback}) when is_binary(feedback),
    do: ["search"]

  defp allowed_actions(%MatchRequest{} = request) do
    @actions
    |> then(fn actions ->
      if MatchRequest.search_allowed?(request), do: actions, else: actions -- ["search"]
    end)
    |> then(fn actions ->
      if request.candidates == [], do: actions -- ["match"], else: actions
    end)
  end

  defp candidate_keys(nil), do: nil

  defp candidate_keys(%MatchRequest{search_feedback: feedback}) when is_binary(feedback),
    do: [nil]

  defp candidate_keys(%MatchRequest{} = request),
    do: [nil | Enum.map(request.candidates, & &1["key"])]

  defp maybe_put_enum(schema, nil), do: schema
  defp maybe_put_enum(schema, values), do: Map.put(schema, "enum", values)

  defp search_query_schema(nil),
    do: %{"type" => ["string", "null"], "maxLength" => 120}

  defp search_query_schema(%MatchRequest{search_feedback: feedback}) when is_binary(feedback),
    do: %{"type" => "string", "minLength" => 1, "maxLength" => 120}

  defp search_query_schema(%MatchRequest{} = request) do
    if MatchRequest.search_allowed?(request),
      do: %{"type" => ["string", "null"], "maxLength" => 120},
      else: %{"type" => "null"}
  end

  defp normalized_action("abstain", nil, search_query, request)
       when is_binary(search_query) do
    if String.trim(search_query) != "" and MatchRequest.search_allowed?(request),
      do: "search",
      else: "abstain"
  end

  defp normalized_action(action, _candidate_key, _search_query, _request), do: action

  defp maybe_note_normalized_action(raw, action, action), do: raw

  defp maybe_note_normalized_action(raw, model_action, action) do
    Map.put(raw, "iri_normalized_action", %{"from" => model_action, "to" => action})
  end

  defp selection_error("match", candidate_key, search_query, request) do
    cond do
      not is_nil(search_query) ->
        "A match decision cannot also request a catalog search."

      not is_binary(candidate_key) ->
        "A match decision must select a supplied candidate."

      not Enum.any?(request.candidates, &(&1["key"] == candidate_key)) ->
        "Model selected a candidate that was not supplied."

      true ->
        nil
    end
  end

  defp selection_error("search", candidate_key, search_query, request) do
    cond do
      not MatchRequest.search_allowed?(request) ->
        "Model requested another catalog search after the search limit was reached."

      not is_nil(candidate_key) ->
        "A catalog search cannot also select a candidate."

      not is_binary(search_query) or String.trim(search_query) == "" ->
        "A catalog search must include a query."

      String.length(String.trim(search_query)) > 120 ->
        "The model's catalog search query was too long."

      true ->
        nil
    end
  end

  defp selection_error(action, candidate_key, search_query, _request)
       when action in ["reject", "keep_store_only", "abstain"] do
    if is_nil(candidate_key) and is_nil(search_query),
      do: nil,
      else:
        "A #{String.replace(action, "_", " ")} decision cannot select or search for a candidate."
  end

  defp selection_error(_action, _candidate_key, _search_query, _request), do: nil

  defp normalized_search_query(search_query) when is_binary(search_query),
    do: String.trim(search_query)

  defp normalized_search_query(_search_query), do: nil

  defp diagnostic(value) when is_binary(value),
    do: value |> Redactor.redact() |> String.slice(0, 2_000)

  defp diagnostic(value) when is_map(value) do
    value
    |> Enum.take(30)
    |> Map.new(fn {key, nested} -> {to_string(key), diagnostic(nested)} end)
  end

  defp diagnostic(value) when is_list(value),
    do: value |> Enum.take(30) |> Enum.map(&diagnostic/1)

  defp diagnostic(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp diagnostic(value), do: value |> Redactor.redact_inspect() |> String.slice(0, 2_000)

  defp invalid_response(message, details \\ nil) do
    %ProviderError{
      category: :invalid_response,
      message: message,
      retryable: false,
      details: details
    }
  end
end
