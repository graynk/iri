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

import Config

config :bcrypt_elixir, :log_rounds, 1

config :iri, Iri.Repo,
  database: Path.expand("../iri_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

config :iri, :steam_client, Iri.Integrations.Steam.ClientStub
config :iri, :gog_client, Iri.Integrations.GOG.ClientStub
config :iri, :protondb_client, Iri.Integrations.ProtonDB.ClientStub
config :iri, :steam_web_api_key, "0123456789abcdef0123456789abcdef"
config :iri, :igdb_client, Iri.Integrations.IGDB.ClientStub
config :iri, :vndb_client, Iri.Integrations.VNDB.ClientStub

config :iri, :igdb_credentials,
  client_id: "fixture-client-id",
  client_secret: "fixture-client-secret"

config :iri, :media_root, Path.join(System.tmp_dir!(), "iri-test-media")
config :iri, :cache_custom_game_covers, false
config :iri, :scheduler_enabled, false
config :iri, :ai_worker_enabled, false
config :iri, :ai_matching, %{provider: :disabled}
config :iri, :on_demand_enrichment_enabled, false

config :iri, IriWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "CdCkTz1fhe4inuNk8TR0z1R/5W9MrTt+8f13x1zrVmQ2aLPHRPXrCr9Fkoop0/DJ",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
