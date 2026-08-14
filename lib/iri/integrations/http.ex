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

defmodule Iri.Integrations.HTTP do
  @moduledoc "Shared Req execution and normalized, redacted failures."

  require Logger

  alias Iri.Integrations.Error

  def request(options, provider \\ nil) when is_list(options) do
    options =
      Keyword.merge(
        [
          receive_timeout: 15_000,
          retry: :transient,
          max_retries: 3,
          retry_log_level: false,
          redirect_log_level: false
        ],
        options
      )
      |> Keyword.put(:retry_log_level, false)
      |> Keyword.put(:redirect_log_level, false)

    case Req.request(options) do
      {:ok, %Req.Response{status: status} = response}
      when status in 200..299 or status == 304 ->
        {:ok, response}

      {:ok, %Req.Response{} = response} ->
        error = Error.from_response(response, provider)

        if provider == :xbox or response.status >= 500 do
          Logger.warning(
            "Provider request failed provider=#{provider || :unknown} status=#{response.status} kind=#{error.kind}#{request_id(response.headers)}"
          )
        end

        {:error, error}

      {:error, exception} ->
        {:error, Error.from_exception(exception, provider)}
    end
  end

  defp request_id(headers) when is_map(headers) do
    case headers["x-request-id"] || headers["request-id"] || headers["x-correlation-id"] do
      [value | _] when is_binary(value) -> " request_id=#{String.slice(value, 0, 100)}"
      value when is_binary(value) -> " request_id=#{String.slice(value, 0, 100)}"
      _value -> ""
    end
  end

  defp request_id(_headers), do: ""
end
