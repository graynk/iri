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

# Runtime configuration shared by development servers and releases.
if System.get_env("PHX_SERVER") do
  config :iri, IriWeb.Endpoint, server: true
end

port = String.to_integer(System.get_env("PORT", "4000"))

config :iri, IriWeb.Endpoint, http: [port: port]

# Development servers can point at an alternate database, such as a demo
# snapshot. Production requires DATABASE_PATH and resolves media beside it below.
dev_database_path = if config_env() == :dev, do: System.get_env("DATABASE_PATH")

if dev_database_path do
  config :iri, Iri.Repo, database: Path.expand(dev_database_path)
end

mode =
  case System.get_env("LIBRARY_MODE", "FAMILY")
       |> String.trim()
       |> String.upcase() do
    "" -> :family
    "FAMILY" -> :family
    "PUBLIC" -> :public
    value -> raise "LIBRARY_MODE must be FAMILY or PUBLIC, got: #{inspect(value)}"
  end

config :iri, :mode, mode

time_zone =
  case System.get_env("TZ") do
    value when is_binary(value) ->
      case String.trim(value) do
        "" -> "Etc/UTC"
        value -> value
      end

    nil ->
      "Etc/UTC"
  end

config :iri, :time_zone, time_zone

nsfw_media =
  case System.get_env("NSFW_MEDIA", "BLUR") |> String.trim() |> String.upcase() do
    "ALLOW" -> :allow
    "BLUR" -> :blur
    "HIDE" -> :hide
    value -> raise "NSFW_MEDIA must be ALLOW, BLUR, or HIDE, got: #{inspect(value)}"
  end

config :iri, :nsfw_media, nsfw_media

download_screenshots =
  case System.get_env("DOWNLOAD_SCREENSHOTS", "false")
       |> String.trim()
       |> String.downcase() do
    "true" -> true
    "false" -> false
    value -> raise "DOWNLOAD_SCREENSHOTS must be true or false, got: #{inspect(value)}"
  end

config :iri, :download_screenshots, download_screenshots

ai_provider = System.get_env("AI_MATCHING_PROVIDER", "disabled")

ai_mode =
  case System.get_env("AI_MATCHING_MODE", "auto") |> String.trim() |> String.downcase() do
    "auto" -> "auto"
    "review" -> "review"
    value -> raise "AI_MATCHING_MODE must be auto or review, got: #{inspect(value)}"
  end

ai_matching = %{
  provider: ai_provider,
  api_key: System.get_env("AI_MATCHING_API_KEY"),
  model: System.get_env("AI_MATCHING_MODEL"),
  base_url: System.get_env("AI_MATCHING_BASE_URL"),
  mode: ai_mode,
  api_style: System.get_env("AI_MATCHING_API_STYLE", "chat_completions"),
  output_format: System.get_env("AI_MATCHING_OUTPUT_FORMAT", "json_schema")
}

config :iri,
  ai_matching: ai_matching,
  ai_worker_enabled: config_env() != :test

non_empty_env = fn variable ->
  case System.get_env(variable) do
    value when is_binary(value) ->
      case String.trim(value) do
        "" -> nil
        value -> value
      end

    nil ->
      nil
  end
end

igdb_client_id = non_empty_env.("IGDB_CLIENT_ID")
igdb_client_secret = non_empty_env.("IGDB_CLIENT_SECRET")
steam_web_api_key = System.get_env("STEAM_WEB_API_KEY")
openxbl_api_key = System.get_env("OPENXBL_API_KEY")

if config_env() != :test and is_binary(steam_web_api_key) and steam_web_api_key != "" do
  config :iri, :steam_web_api_key, steam_web_api_key
end

if config_env() == :prod and (is_nil(igdb_client_id) or is_nil(igdb_client_secret)) do
  raise """
  environment variables IGDB_CLIENT_ID and IGDB_CLIENT_SECRET are missing.
  IRI requires IGDB metadata to import and browse its game library.
  Create an application at https://dev.twitch.tv/console/apps, then set both values.
  """
end

if config_env() != :test and not is_nil(igdb_client_id) and not is_nil(igdb_client_secret) do
  config :iri, :igdb_credentials,
    client_id: igdb_client_id,
    client_secret: igdb_client_secret
end

if config_env() != :test and is_binary(openxbl_api_key) and String.trim(openxbl_api_key) != "" do
  config :iri, :openxbl_api_key, String.trim(openxbl_api_key)
end

if config_env() == :prod do
  positive_integer = fn variable, default ->
    case System.get_env(variable) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _other -> default
        end

      nil ->
        default
    end
  end

  config :iri, scheduler_enabled: true

  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/iri/iri.db
      """

  config :iri, Iri.Repo, database: database_path

  config :iri,
         :media_root,
         System.get_env("MEDIA_ROOT") || Path.join(Path.dirname(database_path), "media")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  configured_host = System.get_env("PHX_HOST")
  host = configured_host || "localhost"
  check_origin = if configured_host, do: true, else: :conn

  external_scheme =
    case System.get_env("PHX_SCHEME", "http")
         |> String.trim()
         |> String.downcase() do
      "http" -> "http"
      "https" -> "https"
      value -> raise "PHX_SCHEME must be http or https, got: #{inspect(value)}"
    end

  default_external_port = if external_scheme == "https", do: 443, else: port
  external_port = positive_integer.("PHX_URL_PORT", default_external_port)

  config :iri, IriWeb.Endpoint,
    url: [host: host, port: external_port, scheme: external_scheme],
    # Without a configured public host, accept a direct-IP origin only when it
    # matches the actual connection. A configured host keeps Phoenix's standard
    # host check, which also works when a proxy terminates TLS upstream.
    check_origin: check_origin,
    http: [
      # Listen on every IPv4/IPv6 interface inside the container.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end
