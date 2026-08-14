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

defmodule IriWeb.Theme do
  @moduledoc "Browser plug that resolves the selected visual theme into the request assigns."

  import Plug.Conn

  @cookie_name "iri-theme"
  @default "dark"
  @options [
    %{label: "Dark", value: "dark", color: "#0f0e17"},
    %{label: "Light", value: "light", color: "#eff0f3"},
    %{label: "Vapor", value: "vapor", color: "#3f4738"},
    %{label: "High Contrast", value: "high-contrast", color: "#000000"},
    %{label: "AI Slop", value: "ai-slop", color: "#020617"}
  ]
  @themes Map.new(@options, &{&1.value, &1.color})

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    assign(conn, :theme, normalize(conn.req_cookies[@cookie_name]))
  end

  @doc "Returns the cookie name used to persist the chosen theme."
  def cookie_name, do: @cookie_name

  @doc "Returns the selectable theme names, labels, and representative colors."
  def options, do: @options

  @doc "Validates a theme name and falls back to the default dark theme."
  def normalize(theme) when is_map_key(@themes, theme), do: theme
  def normalize(_theme), do: @default

  @doc "Returns the representative background color for a valid theme."
  def color(theme), do: Map.fetch!(@themes, normalize(theme))
end
