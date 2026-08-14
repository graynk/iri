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

defmodule Iri.Application do
  @moduledoc "Starts IRI's supervision tree, database migration path, background workers, and endpoint."

  use Application

  @impl true
  def start(_type, _args) do
    :ok = Iri.LocalTime.validate!()

    children =
      [
        Iri.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:iri, :ecto_repos), skip: skip_migrations?()},
        {Phoenix.PubSub, name: Iri.PubSub},
        {Task.Supervisor, name: Iri.Sync.TaskSupervisor},
        Iri.Integrations.GOG.RateLimiter,
        Iri.Integrations.IGDB.RateLimiter,
        Iri.Integrations.IGDB.TokenManager
      ] ++
        ai_worker_child() ++
        scheduler_child() ++
        [IriWeb.Endpoint]

    opts = [strategy: :one_for_one, name: Iri.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    IriWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    System.get_env("RELEASE_NAME") == nil
  end

  defp scheduler_child do
    if Application.get_env(:iri, :scheduler_enabled, false) do
      [Iri.Sync.Scheduler]
    else
      []
    end
  end

  defp ai_worker_child do
    if Application.get_env(:iri, :ai_worker_enabled, false) do
      [Iri.AI.Worker]
    else
      []
    end
  end
end
