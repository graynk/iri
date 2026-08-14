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

defmodule Iri.AI.AdapterStub do
  @behaviour Iri.AI.Adapter

  alias Iri.AI.{MatchDecision, ProviderError}

  @impl true
  def validate_configuration(_config), do: :ok

  @impl true
  def decide(request, _config, options) do
    if error = options[:error] do
      {:error, error}
    else
      search_query =
        case options[:search_queries] do
          queries when is_list(queries) ->
            correction_offset = if is_binary(request.search_feedback), do: 1, else: 0

            if Iri.AI.MatchRequest.search_allowed?(request),
              do: Enum.at(queries, length(request.search_queries) + correction_offset)

          _queries when request.search_queries == [] ->
            options[:search_query]

          _queries ->
            nil
        end

      action = if search_query, do: "search", else: options[:action] || "match"

      candidate = List.first(request.candidates)
      candidate_key = if action == "match", do: candidate["key"]

      {:ok,
       %MatchDecision{
         action: action,
         candidate_key: candidate_key,
         search_query: search_query,
         confidence: options[:confidence] || 0.99,
         reason:
           options[:reason] ||
             if(action == "search",
               do: "Search for the canonical title",
               else: "Fixture recommendation"
             ),
         raw: %{
           "action" => action,
           "candidate_key" => candidate_key,
           "search_query" => search_query,
           "confidence" => options[:confidence] || 0.99,
           "reason" =>
             options[:reason] ||
               if(action == "search",
                 do: "Search for the canonical title",
                 else: "Fixture recommendation"
               )
         }
       }}
    end
  end

  def rate_limited_error do
    %ProviderError{
      category: :rate_limited,
      message: "Fixture rate limit.",
      retryable: true,
      retry_after_seconds: 60
    }
  end

  def authentication_error do
    %ProviderError{
      category: :authentication,
      message: "Fixture authentication failed.",
      retryable: false
    }
  end
end
