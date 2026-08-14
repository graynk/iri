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

defmodule IriWeb.HealthController do
  @moduledoc "Dependency-light liveness endpoint for containers and reverse proxies."

  use IriWeb, :controller

  alias Iri.Repo

  # This endpoint intentionally has no session or authentication dependency so
  # a container runtime or reverse proxy can verify that both the web endpoint
  # and SQLite are available.
  def show(conn, _params) do
    case Repo.query("SELECT 1") do
      {:ok, _result} -> send_resp(conn, :ok, "ok\n")
      {:error, _reason} -> send_resp(conn, :service_unavailable, "database unavailable\n")
    end
  end
end
