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

defmodule Iri.RepoTest do
  use ExUnit.Case, async: true

  alias Iri.Repo

  test "retries a complete transaction after SQLite writer contention" do
    test_process = self()

    transaction = fn fun, opts ->
      send(test_process, {:transaction_attempt, opts})
      attempt = Process.get(:busy_transaction_attempt, 0) + 1
      Process.put(:busy_transaction_attempt, attempt)

      if attempt < 3 do
        raise Exqlite.Error,
          message: "Database busy",
          statement: ~s(DELETE FROM "game_terms" WHERE "game_id" = ?)
      else
        fun.()
      end
    end

    sleep = fn delay_ms -> send(test_process, {:retry_delay, delay_ms}) end

    assert {:ok, :stored} =
             Repo.transact_with_busy_retry(fn -> {:ok, :stored} end,
               mode: :immediate,
               transaction: transaction,
               busy_retry_sleep: sleep,
               busy_retries: 2,
               busy_retry_base_ms: 10
             )

    assert_received {:transaction_attempt, [mode: :immediate]}
    assert_received {:retry_delay, 10}
    assert_received {:transaction_attempt, [mode: :immediate]}
    assert_received {:retry_delay, 20}
    assert_received {:transaction_attempt, [mode: :immediate]}
  end

  test "does not retry unrelated SQLite errors" do
    test_process = self()

    transaction = fn _fun, _opts ->
      send(test_process, :transaction_attempt)
      raise Exqlite.Error, message: "no such table: missing", statement: "SELECT 1"
    end

    sleep = fn _delay_ms -> flunk("unrelated errors must not be retried") end

    assert_raise Exqlite.Error, ~r/no such table/, fn ->
      Repo.transact_with_busy_retry(fn -> {:ok, :unused} end,
        transaction: transaction,
        busy_retry_sleep: sleep
      )
    end

    assert_received :transaction_attempt
    refute_received :transaction_attempt
  end
end
