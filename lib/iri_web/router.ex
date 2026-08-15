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

defmodule IriWeb.Router do
  @moduledoc "HTTP and LiveView route table, including authentication and capability-link boundaries."

  use IriWeb, :router

  import IriWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug IriWeb.Theme
    plug :fetch_live_flash
    plug :put_root_layout, html: {IriWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug :put_capability_headers
  end

  pipeline :health do
    plug :accepts, ["html"]
  end

  # A public, dependency-light route for Docker and reverse-proxy health
  # checks. It must not require a user session because probes do not have one.
  scope "/", IriWeb do
    pipe_through :health

    get "/health", HealthController, :show
  end

  scope "/", IriWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/media/:id", MediaController, :show
  end

  ## Authentication routes

  # This optional-authentication session is declared before the dynamic
  # `/collections/:id` route so the public capability URL cannot be captured
  # as a private collection ID.
  scope "/", IriWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [
        {IriWeb.UserAuth, :mount_current_scope},
        {IriWeb.UserAuth, :enforce_demo_route_policy}
      ] do
      live "/collections/shared", CollectionLive.Shared, :show
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
    end
  end

  scope "/", IriWeb do
    pipe_through [:browser, :require_writable_instance]

    get "/users/log-in/steam", SteamOpenIDController, :start_login
    get "/users/log-in/steam/callback", SteamOpenIDController, :login_callback

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  scope "/", IriWeb do
    pipe_through [:browser, :require_authenticated_user, :require_writable_instance]

    get "/auth/steam", SteamOpenIDController, :start
    get "/auth/steam/callback", SteamOpenIDController, :callback
    post "/settings/update-password", UserSessionController, :update_password
  end

  scope "/", IriWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/collections/:id/export.csv", CollectionExportController, :csv
    get "/collections/:id/export.txt", CollectionExportController, :txt
    get "/collections/:id/export.zip", CollectionExportController, :static

    live_session :require_authenticated_user,
      on_mount: [
        {IriWeb.UserAuth, :require_authenticated},
        {IriWeb.UserAuth, :enforce_demo_route_policy}
      ] do
      live "/library", LibraryLive, :index
      live "/library/statuses", StatusManagerLive, :index
      live "/library/add", CustomGameLive, :new
      live "/collections", CollectionLive.Index, :index
      live "/collections/new", CollectionLive.Form, :new
      live "/collections/:id", CollectionLive.Show, :show
      live "/collections/:id/edit", CollectionLive.Edit, :edit
      live "/games/:slug", GameLive, :show
      live "/companies/:id", CompanyLive, :show
      live "/settings/account", UserLive.Settings, :edit
      live "/settings/integrations", Settings.IntegrationsLive, :index
      live "/settings/integrations/epic/import", Settings.EpicImportLive, :new
      live "/settings/integrations/psn/import", Settings.PSNImportLive, :new
    end
  end

  scope "/", IriWeb do
    pipe_through [
      :browser,
      :require_authenticated_user,
      :require_writable_instance,
      :require_admin_user
    ]

    live_session :require_admin_user,
      on_mount: [
        {IriWeb.UserAuth, :require_admin},
        {IriWeb.UserAuth, :require_writable}
      ] do
      live "/settings/accounts", Settings.AccountsLive, :index
      live "/settings/sync", Settings.SyncLive, :index
      live "/settings/matches", Settings.MatchesLive, :index
      live "/settings/matches/history", Settings.MatchHistoryLive, :index
    end
  end

  defp put_capability_headers(%Plug.Conn{request_path: "/collections/shared"} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("referrer-policy", "no-referrer")
    |> Plug.Conn.put_resp_header("cache-control", "private, no-store")
    |> Plug.Conn.put_resp_header("x-robots-tag", "noindex, nofollow")
  end

  defp put_capability_headers(conn, _opts), do: conn
end
