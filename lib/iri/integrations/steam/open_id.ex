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

defmodule Iri.Integrations.Steam.OpenID do
  @moduledoc "Steam OpenID 2.0 request construction and assertion verification."

  alias Iri.Integrations.Error
  alias Iri.Integrations.HTTP

  @provider_url "https://steamcommunity.com/openid/login"
  @namespace "http://specs.openid.net/auth/2.0"
  @identifier_select "http://specs.openid.net/auth/2.0/identifier_select"
  @claimed_id ~r|^https://steamcommunity\.com/openid/id/(\d{17})$|

  def authentication_url(return_to, realm) do
    query =
      URI.encode_query(%{
        "openid.ns" => @namespace,
        "openid.mode" => "checkid_setup",
        "openid.return_to" => return_to,
        "openid.realm" => realm,
        "openid.identity" => @identifier_select,
        "openid.claimed_id" => @identifier_select
      })

    @provider_url <> "?" <> query
  end

  def verify(params, expected_return_to, options \\ []) when is_map(params) do
    with :ok <- verify_return_to(params, expected_return_to),
         {:ok, steamid} <- extract_steamid(params["openid.claimed_id"]),
         verification_params <- verification_params(params),
         {:ok, response} <- request(verification_params, options),
         true <- valid_response?(response.body) do
      {:ok, steamid}
    else
      {:error, %Error{}} = error -> error
      _other -> {:error, verification_error()}
    end
  end

  defp verify_return_to(%{"openid.return_to" => return_to}, return_to), do: :ok
  defp verify_return_to(_params, _expected), do: {:error, verification_error()}

  defp extract_steamid(claimed_id) when is_binary(claimed_id) do
    case Regex.run(@claimed_id, claimed_id, capture: :all_but_first) do
      [steamid] -> {:ok, steamid}
      _other -> {:error, verification_error()}
    end
  end

  defp extract_steamid(_claimed_id), do: {:error, verification_error()}

  defp verification_params(params) do
    params
    |> Map.filter(fn {key, _value} -> String.starts_with?(key, "openid.") end)
    |> Map.put("openid.mode", "check_authentication")
  end

  defp request(params, options) do
    request_fun = Keyword.get(options, :request, &HTTP.request/2)

    request_fun.(
      [method: :post, url: @provider_url, form: params, retry: false],
      :steam
    )
  end

  defp valid_response?(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.any?(&(String.trim(&1) == "is_valid:true"))
  end

  defp valid_response?(_body), do: false

  defp verification_error do
    %Error{
      kind: :authentication,
      message: "Steam sign-in could not be verified. Please try again.",
      retryable: false,
      provider: :steam
    }
  end
end
