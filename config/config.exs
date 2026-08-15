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

config :iri, :scopes,
  user: [
    default: true,
    module: Iri.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Iri.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :iri,
  ecto_repos: [Iri.Repo],
  generators: [timestamp_type: :utc_datetime],
  mode: :family,
  instance_mode: :normal,
  time_zone: "Etc/UTC"

config :elixir, :time_zone_database, Zoneinfo.TimeZoneDatabase

config :iri, Iri.Repo,
  journal_mode: :wal,
  # SQLite has one writer. A single application connection keeps concurrent
  # import and enrichment workers queued in Ecto instead of making them race
  # for SQLite's writer lock.
  pool_size: 1,
  busy_timeout: 15_000,
  synchronous: :full

# The scheduler is enabled explicitly in production. Keeping it off in local
# development and test prevents background imports from surprising developers.
config :iri,
  scheduler_enabled: false,
  on_demand_enrichment_enabled: true,
  ai_worker_enabled: false,
  ai_matching: %{provider: :disabled},
  download_screenshots: false,
  nsfw_media: :blur

config :iri, IriWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: IriWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Iri.PubSub,
  # Public domain separation; SECRET_KEY_BASE remains the signing secret.
  live_view: [signing_salt: "gP/NEFGO"]

config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  iri: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  iri: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Phoenix and LiveView log request/event parameters in development. Keep the
# filter broad enough for provider callbacks, API-key forms, and capability
# links even though runtime provider keys are not accepted through the UI.
config :phoenix,
       :filter_parameters,
       ~w(password token code secret api_key credential authorization share_token)

import_config "#{config_env()}.exs"
