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

defmodule Iri.Integrations.ProtonDB.Client do
  @moduledoc "Fetches ProtonDB's per-AppID compatibility summary with cache validation."

  alias Iri.Integrations.{Error, HTTP}

  @base_url "https://www.protondb.com/api/v1/reports/summaries"
  @tiers ["platinum", "gold", "silver", "bronze", "borked", "pending"]

  @doc "Fetches one summary, conditionally when a previously returned ETag is available."
  def fetch_tier(app_id, etag, options \\ []) when is_binary(app_id) do
    request_options =
      [
        method: :get,
        url: "#{Keyword.get(options, :base_url, @base_url)}/#{app_id}.json",
        receive_timeout: Keyword.get(options, :receive_timeout, 5_000),
        retry: :safe_transient,
        max_retries: Keyword.get(options, :max_retries, 3)
      ]
      |> maybe_put_etag(etag)

    case request(request_options, options) do
      {:ok, %{status: 304}} ->
        {:ok, :not_modified}

      {:ok, %{body: body} = response} when is_map(body) ->
        {:ok,
         %{
           tier: tier(body["trendingTier"] || body["tier"]),
           etag: response_header(response, "etag")
         }}

      {:error, %Error{status: 404}} ->
        {:ok, %{tier: nil, etag: nil}}

      {:error, _reason} = error ->
        error

      _response ->
        {:error, invalid_response()}
    end
  end

  defp maybe_put_etag(options, etag) when is_binary(etag) and etag != "",
    do: Keyword.put(options, :headers, [{"if-none-match", etag}])

  defp maybe_put_etag(options, _etag), do: options

  defp request(request_options, options) do
    Keyword.get(options, :request, &HTTP.request/2).(request_options, :protondb)
  end

  defp response_header(%Req.Response{} = response, name) do
    response
    |> Req.Response.get_header(name)
    |> List.first()
    |> normalize_etag()
  end

  defp response_header(%{headers: headers}, name) when is_map(headers) do
    headers
    |> Map.get(name, [])
    |> List.wrap()
    |> List.first()
    |> normalize_etag()
  end

  defp response_header(%{headers: headers}, name) when is_list(headers) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: List.wrap(value) |> List.first()
    end)
    |> normalize_etag()
  end

  defp response_header(_response, _name), do: nil

  defp normalize_etag(value) when is_binary(value) and value != "",
    do: String.slice(value, 0, 500)

  defp normalize_etag(_value), do: nil

  defp tier(value) when value in @tiers, do: value
  defp tier(_value), do: nil

  defp invalid_response do
    %Error{
      kind: :invalid_response,
      message: "ProtonDB returned an invalid compatibility summary.",
      retryable: true,
      provider: :protondb
    }
  end
end
