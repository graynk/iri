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

defmodule Iri.Integrations.HTTPTest do
  use ExUnit.Case, async: true

  alias Iri.Integrations.HTTP

  setup {Req.Test, :verify_on_exit!}

  test "accepts not-modified responses" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 304, "") end)

    assert {:ok, %Req.Response{status: 304}} =
             HTTP.request(
               [method: :get, url: "https://protondb.test/summary", plug: {Req.Test, __MODULE__}],
               :protondb
             )
  end

  test "retries a rate limit using Retry-After" do
    attempts = start_supervised!({Agent, fn -> 0 end})

    Req.Test.expect(__MODULE__, 2, fn conn ->
      attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})

      if attempt == 0 do
        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.send_resp(429, "retry later")
      else
        Plug.Conn.send_resp(conn, 200, "ok")
      end
    end)

    assert {:ok, %Req.Response{status: 200}} =
             HTTP.request(
               [method: :get, url: "https://protondb.test/summary", plug: {Req.Test, __MODULE__}],
               :protondb
             )

    assert Agent.get(attempts, & &1) == 2
  end
end
