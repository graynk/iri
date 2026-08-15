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

defmodule IriWeb.UserAuth do
  @moduledoc "Browser and LiveView authentication plugs, session handling, and authorization mounts."

  use IriWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Iri.Accounts
  alias Iri.Accounts.Scope
  alias Iri.{Demo, InstancePolicy}

  # Keep this in sync with the session validity in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_iri_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # Rotate active browser tokens halfway through their lifetime.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in.

  Redirects to the appropriate signed-in path.
  """
  def log_in_user(conn, user, params \\ %{}) do
    if InstancePolicy.demo?() do
      redirect(conn, to: ~p"/library")
    else
      conn
      |> issue_user_session(user, params)
      |> redirect(to: signed_in_path(conn))
    end
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    if InstancePolicy.demo?() do
      redirect(conn, to: ~p"/library")
    else
      user_token = get_session(conn, :user_token)
      user_token && Accounts.delete_user_session_token(user_token)

      if live_socket_id = get_session(conn, :live_socket_id) do
        IriWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
      end

      conn
      |> renew_session(nil)
      |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
      |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    if InstancePolicy.demo?() do
      assign(conn, :current_scope, Demo.scope())
    else
      with {token, conn} <- ensure_user_token(conn),
           {user, token_inserted_at} <- Accounts.get_user_by_session_token(token) do
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> reissue_session_if_old(user, token_inserted_at)
      else
        nil -> assign(conn, :current_scope, Scope.for_user(nil))
      end
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  defp reissue_session_if_old(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      issue_user_session(conn, user, %{})
    else
      conn
    end
  end

  defp issue_user_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> update_remember_me(token, params, remember_me)
  end

  # Preserve the browser session when refreshing a token for the same user.
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # A new login gets a new session ID and no data from the anonymous session.
  defp renew_session(conn, _user) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp update_remember_me(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp update_remember_me(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp update_remember_me(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      IriWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule IriWeb.PageLive do
        use IriWeb, :live_view

        on_mount {IriWeb.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{IriWeb.UserAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, maybe_protect_demo_events(socket)}
    else
      # Bouncing a logged-out visitor to log in (or, on a fresh instance, to
      # registration) is self-explanatory; no error toast needed.
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_out_path())}
    end
  end

  def on_mount(:enforce_demo_route_policy, _params, _session, socket) do
    if InstancePolicy.demo?() and socket.view not in demo_read_views() do
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:info, "This public demo is read-only.")
       |> Phoenix.LiveView.redirect(to: ~p"/library")}
    else
      {:cont, socket}
    end
  end

  def on_mount(:require_writable, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if InstancePolicy.demo?() do
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:info, "This public demo is read-only.")
       |> Phoenix.LiveView.redirect(to: ~p"/library")}
    else
      {:cont, socket}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    cond do
      is_nil(socket.assigns.current_scope) ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/users/log-in")}

      Scope.admin?(socket.assigns.current_scope) ->
        {:cont, socket}

      true ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Administrator access is required.")
         |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end

  defp mount_current_scope(socket, session) do
    socket = Phoenix.Component.assign(socket, :demo?, InstancePolicy.demo?())

    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      if InstancePolicy.demo?() do
        Demo.scope()
      else
        {user, _} =
          if user_token = session["user_token"] do
            Accounts.get_user_by_session_token(user_token)
          end || {nil, nil}

        Scope.for_user(user)
      end
    end)
  end

  @demo_read_events %{
    IriWeb.LibraryLive => ~w(filter add_tag remove_tag toggle_filters toggle_sort_direction),
    IriWeb.StatusManagerLive =>
      ~w(filter toggle_sort_direction toggle_selection select_range toggle_page_selection clear_selection mark_viewed restore_viewed sync_viewed),
    IriWeb.GameLive =>
      ~w(show_screenshot reveal_sensitive_media close_screenshot previous_screenshot next_screenshot load_trailer close_trailer),
    IriWeb.CollectionLive.Index => [],
    IriWeb.CollectionLive.Show => ~w(sort_collection load_more),
    IriWeb.CompanyLive => []
  }

  defp demo_read_views do
    [IriWeb.CollectionLive.Shared | Map.keys(@demo_read_events)]
  end

  defp maybe_protect_demo_events(socket) do
    if InstancePolicy.demo?() do
      Phoenix.LiveView.attach_hook(socket, :demo_read_only, :handle_event, fn event,
                                                                              _params,
                                                                              socket ->
        if event in Map.get(@demo_read_events, socket.view, []) do
          {:cont, socket}
        else
          {:halt, Phoenix.LiveView.put_flash(socket, :info, "This public demo is read-only.")}
        end
      end)
    else
      socket
    end
  end

  @doc "Returns the path to redirect to after log in."
  # the user was already logged in, redirect to settings
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{user: %Accounts.User{}}}}) do
    ~p"/settings/account"
  end

  def signed_in_path(_), do: ~p"/library"

  @doc """
  Returns where to send a visitor who needs an account.

  On a fresh instance there is nobody to log in as, so the login form is a dead
  end. Send the first visitor to registration instead.
  """
  def signed_out_path do
    if Accounts.first_user_registration?() do
      ~p"/users/register"
    else
      ~p"/users/log-in"
    end
  end

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> redirect(to: signed_out_path())
      |> halt()
    end
  end

  @doc "Plug for routes that must never be available in read-only demo mode."
  def require_writable_instance(conn, _opts) do
    if InstancePolicy.demo?() do
      conn
      |> put_flash(:info, "This public demo is read-only.")
      |> redirect(to: ~p"/library")
      |> halt()
    else
      conn
    end
  end

  @doc "Plug for controller routes that require an administrator."
  def require_admin_user(conn, _opts) do
    if Scope.admin?(conn.assigns.current_scope) do
      conn
    else
      conn
      |> put_flash(:error, "Administrator access is required.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end
end
