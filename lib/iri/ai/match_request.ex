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

defmodule Iri.AI.MatchRequest do
  @moduledoc "Sanitized source and candidate data sent to a model adapter."

  @max_searches 2

  @enforce_keys [:source, :candidates]
  defstruct [
    :source,
    :candidates,
    :search_feedback,
    search_queries: [],
    search_attempts: []
  ]

  @type t :: %__MODULE__{
          source: map(),
          candidates: [map()],
          search_queries: [String.t()],
          search_attempts: [map()],
          search_feedback: String.t() | nil
        }

  def max_searches, do: @max_searches

  def search_allowed?(%__MODULE__{search_queries: queries}),
    do: length(queries) < @max_searches

  def provider_payload(%__MODULE__{} = request) do
    payload = %{
      "source" => request.source,
      "candidates" => Enum.map(request.candidates, &Map.drop(&1, ["external_id"])),
      "catalog_search_attempts" => request.search_attempts
    }

    if is_binary(request.search_feedback),
      do: Map.put(payload, "search_correction", request.search_feedback),
      else: payload
  end
end
