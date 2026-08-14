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

defmodule Iri.AI.Provider do
  @moduledoc "Shared HTTP request and error handling for AI adapters."

  alias Iri.AI.ProviderError

  @request_timeout_ms 60_000

  @doc "Executes one provider request with a fixed timeout and returns a redacted, normalized result."
  def request(options, provider, adapter_options) do
    request = Keyword.get(adapter_options, :request, &Req.request/1)

    options =
      Keyword.merge(
        [receive_timeout: @request_timeout_ms, retry: false, redirect: false],
        options
      )

    result =
      try do
        request.(options)
      rescue
        exception -> {:error, exception}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{} = response} ->
        {:error, response_error(response, provider)}

      {:error, reason} ->
        {:error,
         %ProviderError{
           category: if(timeout?(reason), do: :timeout, else: :transport),
           message:
             if(timeout?(reason),
               do: "#{provider_name(provider)} request timed out.",
               else: "#{provider_name(provider)} could not be reached."
             ),
           retryable: true
         }}
    end
  end

  @doc "Joins a configured provider base URL and endpoint without duplicating `/v1`."
  def endpoint(base_url, path) do
    base_url = String.trim_trailing(base_url, "/")

    cond do
      String.ends_with?(base_url, path) ->
        base_url

      String.ends_with?(base_url, "/v1") and String.starts_with?(path, "/v1/") ->
        base_url <> String.replace_prefix(path, "/v1", "")

      true ->
        base_url <> path
    end
  end

  defp response_error(response, provider) do
    category =
      case response.status do
        status when status in [401, 403] -> :authentication
        429 -> :rate_limited
        status when status >= 500 -> :provider_5xx
        _status -> :invalid_response
      end

    %ProviderError{
      category: category,
      message: "#{provider_name(provider)} returned HTTP #{response.status}.",
      retryable: category in [:rate_limited, :provider_5xx],
      retry_after_seconds: retry_after(response.headers),
      status: response.status
    }
  end

  defp retry_after(headers) do
    case header(headers, "retry-after") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, ""} when seconds > 0 -> seconds
          _invalid -> nil
        end

      _value ->
        nil
    end
  end

  defp header(headers, name) when is_map(headers) do
    case headers[name] do
      [value | _rest] -> value
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp header(_headers, _name), do: nil

  defp timeout?(%Req.TransportError{reason: reason}), do: reason in [:timeout, :connect_timeout]
  defp timeout?({:timeout, _reason}), do: true
  defp timeout?(:timeout), do: true
  defp timeout?(_reason), do: false

  defp provider_name(:openai), do: "OpenAI"
  defp provider_name(:anthropic), do: "Anthropic"
  defp provider_name(:openai_compatible), do: "AI endpoint"
end
