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

defmodule IriWeb.SteamOpenIDController do
  @moduledoc "Steam OpenID connection and sign-in handshake endpoints."

  use IriWeb, :controller

  alias Iri.Accounts
  alias Iri.Accounts.Scope
  alias Iri.Integrations
  alias Iri.Integrations.Steam.OpenID
  alias Iri.Sync
  alias IriWeb.UserAuth

  def start(conn, _params) do
    begin_open_id(conn, :connect, &connect_callback_url/1)
  end

  def start_login(conn, _params) do
    begin_open_id(conn, :login, &login_callback_url/1)
  end

  defp begin_open_id(conn, purpose, callback_url_fun) do
    state = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    return_to = callback_url_fun.(state)
    realm = url(~p"/")

    conn
    |> put_session(:steam_openid, %{state: state, purpose: purpose})
    |> redirect(external: OpenID.authentication_url(return_to, realm))
  end

  def callback(conn, %{"state" => state} = params) do
    expected_state = open_id_state(conn, :connect)

    result =
      if is_binary(expected_state) and Plug.Crypto.secure_compare(expected_state, state) do
        OpenID.verify(params, connect_callback_url(state))
      else
        {:error, :invalid_state}
      end

    conn = delete_session(conn, :steam_openid)

    case result do
      {:ok, steamid} ->
        conn
        |> put_flash(
          :info,
          "Steam account selected. Validate it with the server's configured Web API key."
        )
        |> redirect(to: ~p"/settings/integrations?steamid=#{steamid}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Steam sign-in could not be verified. Please try again.")
        |> redirect(to: ~p"/settings/integrations")
    end
  end

  def callback(conn, _params) do
    conn
    |> delete_session(:steam_openid)
    |> put_flash(:error, "Steam sign-in was cancelled or incomplete.")
    |> redirect(to: ~p"/settings/integrations")
  end

  def login_callback(conn, %{"state" => state} = params) do
    expected_state = open_id_state(conn, :login)

    result =
      if is_binary(expected_state) and Plug.Crypto.secure_compare(expected_state, state) do
        OpenID.verify(params, login_callback_url(state))
      else
        {:error, :invalid_state}
      end

    conn = delete_session(conn, :steam_openid)

    case result do
      {:ok, steam_id} -> finish_steam_login(conn, steam_id)
      {:error, _reason} -> steam_login_failed(conn)
    end
  end

  def login_callback(conn, _params) do
    conn
    |> delete_session(:steam_openid)
    |> steam_login_failed()
  end

  defp finish_steam_login(%{assigns: %{current_scope: %{user: user}}} = conn, steam_id)
       when not is_nil(user) do
    case Accounts.link_steam_identity(conn.assigns.current_scope, steam_id) do
      {:ok, user} ->
        connect_steam_library(user, steam_id)

        conn
        |> put_flash(:info, "Steam sign-in linked to your IRI account.")
        |> redirect(to: ~p"/settings/account")

      {:error, :steam_identity_taken} ->
        conn
        |> put_flash(:error, "That Steam account is already linked to another IRI user.")
        |> redirect(to: ~p"/settings/account")
    end
  end

  defp finish_steam_login(conn, steam_id) do
    case Accounts.get_or_register_steam_user(steam_id) do
      {:ok, user} ->
        connect_steam_library(user, steam_id)

        conn
        |> put_flash(:info, "Signed in with Steam.")
        |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

      {:error, :registration_closed} ->
        conn
        |> put_flash(
          :error,
          "This Steam account is not linked to an IRI user. Ask the administrator to create your Family-mode account first."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, _reason} ->
        steam_login_failed(conn)
    end
  end

  defp connect_steam_library(user, steam_id) do
    scope = Scope.for_user(user)

    with {:ok, %{account: account}} <-
           Integrations.connect_steam(scope, %{"profile" => steam_id}),
         {:ok, _run} <- Sync.start_steam_sync(scope, account.id) do
      :ok
    else
      _reason -> :ok
    end
  end

  defp steam_login_failed(conn) do
    conn
    |> put_flash(:error, "Steam sign-in could not be verified. Please try again.")
    |> redirect(to: ~p"/users/log-in")
  end

  defp open_id_state(conn, purpose) do
    case get_session(conn, :steam_openid) do
      %{"state" => state, "purpose" => session_purpose} ->
        if session_purpose == Atom.to_string(purpose), do: state

      %{state: state, purpose: session_purpose} ->
        if session_purpose == purpose, do: state

      _session ->
        nil
    end
  end

  defp connect_callback_url(state), do: url(~p"/auth/steam/callback?state=#{state}")

  defp login_callback_url(state),
    do: url(~p"/users/log-in/steam/callback?state=#{state}")
end
