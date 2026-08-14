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

defmodule Iri.Repo do
  @moduledoc "SQLite-backed Ecto repository for IRI's durable state."

  use Ecto.Repo,
    otp_app: :iri,
    adapter: Ecto.Adapters.SQLite3

  @default_busy_retries 4
  @default_busy_retry_base_ms 100
  @max_busy_retry_delay_ms 2_000

  @doc """
  Runs a transaction again when SQLite could not obtain its single writer lock.

  The entire transaction is retried so callers never continue from a partially
  applied metadata replacement. Other database and changeset errors are
  returned or raised without retrying.
  """
  def transact_with_busy_retry(fun, opts \\ []) when is_function(fun) do
    {busy_retries, opts} = Keyword.pop(opts, :busy_retries, @default_busy_retries)

    {base_delay_ms, opts} =
      Keyword.pop(opts, :busy_retry_base_ms, @default_busy_retry_base_ms)

    {sleep, opts} = Keyword.pop(opts, :busy_retry_sleep, &Process.sleep/1)

    {transaction, opts} =
      Keyword.pop(opts, :transaction, fn transaction_fun, transaction_opts ->
        transact(transaction_fun, transaction_opts)
      end)

    retry_busy_transaction(
      fun,
      opts,
      transaction,
      sleep,
      busy_retries,
      base_delay_ms,
      0
    )
  end

  @doc "Runs SQLite's full integrity check against the current database."
  def integrity_check do
    case query("PRAGMA integrity_check") do
      {:ok, %{rows: [["ok"]]}} -> :ok
      {:ok, %{rows: rows}} -> {:error, {:integrity_check_failed, rows}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_busy_transaction(
         fun,
         opts,
         transaction,
         sleep,
         busy_retries,
         base_delay_ms,
         attempt
       ) do
    try do
      case transaction.(fun, opts) do
        {:error, %Exqlite.Error{} = error} = result ->
          if busy_error?(error) and attempt < busy_retries do
            sleep.(busy_retry_delay(base_delay_ms, attempt))

            retry_busy_transaction(
              fun,
              opts,
              transaction,
              sleep,
              busy_retries,
              base_delay_ms,
              attempt + 1
            )
          else
            result
          end

        result ->
          result
      end
    rescue
      error in Exqlite.Error ->
        if busy_error?(error) and attempt < busy_retries do
          sleep.(busy_retry_delay(base_delay_ms, attempt))

          retry_busy_transaction(
            fun,
            opts,
            transaction,
            sleep,
            busy_retries,
            base_delay_ms,
            attempt + 1
          )
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  defp busy_error?(%Exqlite.Error{message: message}) when is_binary(message) do
    message = String.downcase(message)

    String.contains?(message, [
      "database busy",
      "database is busy",
      "database locked",
      "database is locked"
    ])
  end

  defp busy_error?(_error), do: false

  defp busy_retry_delay(base_delay_ms, attempt) do
    min(base_delay_ms * Integer.pow(2, attempt), @max_busy_retry_delay_ms)
  end
end
