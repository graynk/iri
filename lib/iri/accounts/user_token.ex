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

defmodule Iri.Accounts.UserToken do
  @moduledoc """
  Database records for authenticated browser tokens.

  IRI uses Phoenix's signed cookie sessions. `IriWeb.UserAuth` stores a random
  session token in that cookie and this table records the matching token,
  allowing the server to enforce its 14-day lifetime and revoke active logins.
  """

  use Ecto.Schema
  import Ecto.Query
  alias Iri.Accounts.UserToken

  @rand_size 32

  @session_validity_in_days 14

  schema "users_tokens" do
    field :token, :binary
    belongs_to :user, Iri.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Creates a random browser-session token and its database record.

  `IriWeb.UserAuth` places the returned token in Phoenix's signed session
  cookie and, when requested, its signed persistent remember-me cookie. The
  database record is the server-side validity and revocation check; the token
  value is stored verbatim rather than hashed.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %UserToken{token: token, user_id: user.id}}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any, along with the token's creation time.

  The token is valid if it matches the value in the database and it has
  not expired (after @session_validity_in_days).
  """
  def verify_session_token_query(token) do
    query =
      from token in UserToken,
        where: token.token == ^token,
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: {user, token.inserted_at}

    {:ok, query}
  end
end
