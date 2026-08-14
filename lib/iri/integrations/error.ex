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

defmodule Iri.Integrations.Error do
  @moduledoc "A redacted, provider-independent integration failure."

  alias Iri.Security.Redactor

  @enforce_keys [:kind, :message, :retryable]
  defstruct [:kind, :message, :retryable, :status, :provider, :retry_after_seconds]

  @type t :: %__MODULE__{
          kind: atom(),
          message: String.t(),
          retryable: boolean(),
          status: non_neg_integer() | nil,
          provider: atom() | nil,
          retry_after_seconds: non_neg_integer() | nil
        }

  def from_response(%Req.Response{status: status, body: body, headers: headers}, provider \\ nil) do
    provider_name = provider_name(provider)
    detail = response_detail(body)

    %__MODULE__{
      kind: status_kind(status),
      message:
        "#{provider_name} returned HTTP #{status}" <>
          if(detail, do: ": #{detail}", else: "."),
      retryable: status == 429 or status >= 500,
      status: status,
      provider: provider,
      retry_after_seconds: retry_after_seconds(headers)
    }
  end

  def from_exception(exception, provider \\ nil) do
    %__MODULE__{
      kind: :transport,
      message: exception |> Redactor.exception_message() |> String.slice(0, 500),
      retryable: true,
      provider: provider
    }
  end

  defp status_kind(status) when status in [401, 403], do: :authentication
  defp status_kind(404), do: :not_found
  defp status_kind(429), do: :rate_limited
  defp status_kind(status) when status >= 500, do: :provider_unavailable
  defp status_kind(_status), do: :unexpected_response

  defp response_detail(body) when is_map(body) do
    value = body["message"] || body["error_description"] || body["error"]

    if is_binary(value) do
      value
      |> Redactor.redact()
      |> String.trim()
      |> String.slice(0, 200)
      |> case do
        "" -> nil
        detail -> detail
      end
    end
  end

  defp response_detail(body) when is_binary(body) do
    if String.valid?(body) do
      body
      |> Redactor.redact()
      |> String.trim()
      |> String.slice(0, 200)
      |> case do
        "" -> nil
        detail -> detail
      end
    else
      nil
    end
  end

  defp response_detail(_body), do: nil

  defp retry_after_seconds(headers) when is_map(headers) do
    headers
    |> Map.get("retry-after")
    |> List.wrap()
    |> List.first()
    |> parse_non_negative_integer()
  end

  defp retry_after_seconds(_headers), do: nil

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> seconds
      _invalid -> nil
    end
  end

  defp parse_non_negative_integer(_value), do: nil

  defp provider_name(:xbox), do: "OpenXBL"
  defp provider_name(nil), do: "Provider"
  defp provider_name(provider), do: provider |> to_string() |> String.upcase()
end
