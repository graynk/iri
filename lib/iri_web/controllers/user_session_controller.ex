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

defmodule IriWeb.UserSessionController do
  @moduledoc "Password session creation, renewal, and logout endpoints."

  use IriWeb, :controller

  alias Iri.Accounts
  alias IriWeb.UserAuth

  def create(conn, %{"_action" => "registered"} = params) do
    create(conn, params, "Account created. Welcome to IRI!")
  end

  def create(conn, params) do
    create(conn, params, nil)
  end

  # username + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"username" => username, "password" => password} = user_params

    if user = Accounts.get_user_by_username_and_password(username, password) do
      conn
      |> maybe_put_info(info)
      |> UserAuth.log_in_user(user, user_params)
    else
      # Don't disclose whether the username is registered.
      conn
      |> put_flash(:error, "Invalid username or password")
      |> put_flash(:username, String.slice(username, 0, 40))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end

  defp maybe_put_info(conn, nil), do: conn
  defp maybe_put_info(conn, message), do: put_flash(conn, :info, message)
end
