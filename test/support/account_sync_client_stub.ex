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

defmodule Iri.Sync.AccountSyncClientStub do
  @behaviour Iri.Integrations.Provider

  @impl true
  def fetch_library(account, _credentials, options) do
    case Keyword.get(options, :mode, :success) do
      :success ->
        {:ok, entries(account.provider)}

      :block ->
        test_pid = Keyword.fetch!(options, :test_pid)
        send(test_pid, {:account_sync_fetching, account.provider, self()})

        receive do
          :release_account_sync -> {:ok, entries(account.provider)}
        end

      {:error, reason} ->
        {:error, reason}

      {:raise, message} ->
        raise message
    end
  end

  defp entries(:steam) do
    [
      %{
        "appid" => 90_001,
        "name" => "Account sync fixture",
        "playtime_forever" => 30
      }
    ]
  end

  defp entries(:gog) do
    [
      %{
        "id" => "90001",
        "title" => "Account sync fixture",
        "url" => "/game/account_sync_fixture",
        "stats" => %{"playtime" => 30}
      }
    ]
  end

  defp entries(:xbox) do
    [
      %{
        external_id: "90001",
        title: "Account sync fixture",
        relationship: :played,
        playtime_minutes: 30,
        metadata: %{}
      }
    ]
  end
end
