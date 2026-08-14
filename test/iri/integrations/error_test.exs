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

defmodule Iri.Integrations.ErrorTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.Error

  test "normalizes retryable HTTP responses" do
    error =
      Error.from_response(
        %Req.Response{status: 429, headers: %{"retry-after" => ["12"]}},
        :igdb
      )

    assert error.kind == :rate_limited
    assert error.retryable
    assert error.status == 429
    assert error.provider == :igdb
    assert error.retry_after_seconds == 12
  end

  test "retains redacted plain-text provider errors" do
    error =
      Error.from_response(
        %Req.Response{
          status: 400,
          body: "Too much data selected for token=super-secret"
        },
        :vndb
      )

    assert error.message =~ "Too much data selected"
    refute error.message =~ "super-secret"
    refute error.retryable
  end

  test "does not copy compressed response bytes into an error message" do
    gzip_body = <<31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 203, 43, 205, 201>>
    error = Error.from_response(%Req.Response{status: 429, body: gzip_body}, :steam)

    assert error.message == "STEAM returned HTTP 429."
    assert String.valid?(error.message)
  end

  test "redacts common credentials from transport messages" do
    error =
      Error.from_exception(
        RuntimeError.exception("failed https://example.test/?key=secret&code=also-secret"),
        :steam
      )

    refute error.message =~ "secret"
    assert error.message =~ "[REDACTED]"
  end
end
