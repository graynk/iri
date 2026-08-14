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

defmodule Iri.Integrations.Xbox.RateLimiter do
  @moduledoc "Database-coordinated OpenXBL hourly budget with a safety reserve."

  import Ecto.Query, warn: false

  alias Iri.Integrations.ProviderRateLimit
  alias Iri.Repo

  @provider "openxbl"
  @hourly_limit 150
  @reserve 10

  def acquire(now \\ DateTime.utc_now(:second)) do
    Repo.transact(
      fn ->
        row = Repo.get_by(ProviderRateLimit, provider: @provider)
        row = reset_if_expired(row, now)

        cond do
          row && row.blocked_until && DateTime.compare(row.blocked_until, now) == :gt ->
            Repo.rollback({:rate_limited, row.blocked_until})

          row && row.requests_observed >= @hourly_limit - @reserve ->
            Repo.rollback({:rate_limited, row.window_ends_at})

          true ->
            attrs =
              if row do
                %{requests_observed: row.requests_observed + 1}
              else
                %{
                  provider: @provider,
                  requests_observed: 1,
                  window_ends_at: DateTime.add(now, 3600, :second)
                }
              end

            result =
              (row || %ProviderRateLimit{})
              |> ProviderRateLimit.changeset(attrs)
              |> Repo.insert_or_update()

            case result do
              {:ok, _limit} -> {:ok, :acquired}
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, :acquired} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def observe(headers, status, now \\ DateTime.utc_now(:second)) do
    reset = reset_datetime(headers, now)
    retry_after = header_integer(headers, "retry-after")

    Repo.get_by(ProviderRateLimit, provider: @provider)
    |> case do
      nil ->
        :ok

      row ->
        blocked_until =
          if status == 429, do: reset || DateTime.add(now, retry_after || 3600, :second)

        row
        |> ProviderRateLimit.changeset(%{
          window_ends_at: reset || row.window_ends_at,
          blocked_until: blocked_until
        })
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          _ -> :ok
        end
    end
  end

  defp reset_if_expired(nil, _now), do: nil

  defp reset_if_expired(row, now) do
    if row.window_ends_at && DateTime.compare(row.window_ends_at, now) != :gt do
      {:ok, row} =
        row
        |> ProviderRateLimit.changeset(%{
          requests_observed: 0,
          blocked_until: nil,
          window_ends_at: DateTime.add(now, 3600, :second)
        })
        |> Repo.update()

      row
    else
      row
    end
  end

  defp header_integer(headers, name) do
    headers
    |> header(name)
    |> then(fn value ->
      case Integer.parse(value || "") do
        {number, _} -> number
        _ -> nil
      end
    end)
  end

  defp reset_datetime(headers, now) do
    case header_integer(headers, "x-ratelimit-reset") do
      value when is_integer(value) and value > 1_000_000_000 ->
        case DateTime.from_unix(value) do
          {:ok, dt} -> dt
          _ -> nil
        end

      value when is_integer(value) and value > 0 ->
        DateTime.add(now, value, :second)

      _ ->
        nil
    end
  end

  defp header(headers, name) when is_map(headers),
    do: headers |> Map.get(name, []) |> List.wrap() |> List.first()

  defp header(headers, name) when is_list(headers),
    do:
      headers
      |> Enum.find_value(fn {key, value} ->
        if String.downcase(to_string(key)) == name, do: List.wrap(value) |> List.first()
      end)

  defp header(_headers, _name), do: nil
end
