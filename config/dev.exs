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

config :iri, Iri.Repo,
  database: Path.expand("../iri_dev.db", __DIR__),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :iri, :media_root, Path.expand("../data/media", __DIR__)

config :iri, IriWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "GN6sc0pbAB5pd283RK++yUOXy01IBKUAFbi0Un9rnrUEXV2eV6tB/EKRlJidQjDa",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:iri, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:iri, ~w(--watch)]}
  ],
  live_reload: [
    web_console_logger: true,
    patterns: [
      # Static assets, except user uploads
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
      # Router, Controllers, LiveViews and LiveComponents
      ~r"lib/iri_web/router\.ex$",
      ~r"lib/iri_web/(controllers|live|components)/.*\.(ex|heex)$"
    ]
  ]

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true
