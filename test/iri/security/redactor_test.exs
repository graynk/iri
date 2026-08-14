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

defmodule Iri.Security.RedactorTest do
  use ExUnit.Case, async: true

  alias Iri.Security.Redactor

  test "redacts OAuth query parameters, inspected values, and bearer headers" do
    code = "gog-one-time-code"
    token = "access-token-value"
    secret = "igdb-client-secret"

    redacted =
      Redactor.redact(
        "https://auth.example/callback?code=#{code}&client_secret=#{secret} authorization: Bearer #{token}"
      )

    refute redacted =~ code
    refute redacted =~ secret
    refute redacted =~ token
    assert redacted =~ "code=[REDACTED]"
    assert redacted =~ "client_secret=[REDACTED]"
    assert redacted =~ "authorization: [REDACTED]"

    inspected = Redactor.redact_inspect(%{"refresh_token" => token, "api_key" => secret})
    refute inspected =~ token
    refute inspected =~ secret

    openxbl = Redactor.redact_inspect(%{"x-authorization" => "openxbl-private-key"})
    refute openxbl =~ "openxbl-private-key"
  end

  test "Phoenix filters credential-bearing LiveView event parameters" do
    params = %{
      "gog_connection_form" => %{"code" => "gog-one-time-code"},
      "steam_connection_form" => %{"api_key" => "steam-api-key"},
      "igdb" => %{"client_secret" => "igdb-client-secret"}
    }

    assert Phoenix.Logger.filter_values(params) == %{
             "gog_connection_form" => %{"code" => "[FILTERED]"},
             "steam_connection_form" => %{"api_key" => "[FILTERED]"},
             "igdb" => %{"client_secret" => "[FILTERED]"}
           }
  end
end
