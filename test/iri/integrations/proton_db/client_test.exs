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

defmodule Iri.Integrations.ProtonDB.ClientTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.Error
  alias Iri.Integrations.ProtonDB.Client

  test "sends a stored ETag and captures the replacement validator" do
    request = fn options, :protondb ->
      send(self(), {:request, options})

      {:ok,
       %{
         status: 200,
         headers: %{"etag" => [~s("new-etag")]},
         body: %{"tier" => "silver", "trendingTier" => "gold"}
       }}
    end

    assert {:ok, %{tier: "gold", etag: ~s("new-etag")}} =
             Client.fetch_tier("620", ~s("old-etag"), request: request)

    assert_received {:request, options}
    assert options[:headers] == [{"if-none-match", ~s("old-etag")}]
    assert options[:receive_timeout] == 5_000
    assert options[:retry] == :safe_transient
    assert options[:max_retries] == 3
    refute Keyword.has_key?(options, :retry_delay)
  end

  test "recognizes a 304 response as a successful cache validation" do
    request = fn options, :protondb ->
      send(self(), {:request, options})
      {:ok, %{status: 304, headers: %{}, body: ""}}
    end

    assert {:ok, :not_modified} =
             Client.fetch_tier("620", ~s("current-etag"), request: request)

    assert_received {:request, options}
    assert options[:headers] == [{"if-none-match", ~s("current-etag")}]
  end

  test "treats a missing ProtonDB summary as a completed empty result" do
    request = fn _options, :protondb ->
      {:error,
       %Error{
         kind: :not_found,
         message: "ProtonDB returned HTTP 404.",
         retryable: false,
         status: 404,
         provider: :protondb
       }}
    end

    assert {:ok, %{tier: nil, etag: nil}} = Client.fetch_tier("999", nil, request: request)
  end
end
