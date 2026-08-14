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

defmodule Iri.Accounts.User do
  @moduledoc "Local user identity, authentication credentials, and personal display preferences."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Integrations.ProviderAccount

  schema "users" do
    field :username, :string
    field :steam_id, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :role, Ecto.Enum, values: [:admin, :viewer], default: :viewer

    belongs_to :main_steam_account, ProviderAccount

    field :sensitive_media_mode, Ecto.Enum,
      values: [:inherit, :blur, :hide, :allow],
      default: :inherit

    timestamps(type: :utc_datetime)
  end

  @doc "A changeset for local username/password registration."
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> username_changeset(attrs, opts)
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  def username_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:username])
    |> update_change(:username, &String.trim/1)
    |> validate_required([:username])
    |> validate_format(:username, ~r/^[\p{L}\p{N}_.-]+$/u,
      message: "may only contain letters, numbers, dots, dashes, and underscores"
    )
    |> validate_length(:username, min: 2, max: 40)
    |> maybe_validate_unique_username(opts)
  end

  def steam_changeset(user, steam_id, username) do
    user
    |> change(
      steam_id: steam_id,
      username: username
    )
    |> validate_required([:steam_id, :username])
    |> unique_constraint(:steam_id)
    |> unique_constraint(:username)
  end

  def admin?(%__MODULE__{role: :admin}), do: true
  def admin?(_user), do: false

  def sensitive_media_changeset(user, attrs) do
    user
    |> cast(attrs, [:sensitive_media_mode])
    |> validate_required([:sensitive_media_mode])
  end

  def main_steam_account_changeset(user, account_id) do
    change(user, main_steam_account_id: account_id)
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 6, max: 72)
    |> maybe_hash_password(opts)
  end

  defp maybe_validate_unique_username(changeset, opts) do
    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:username, Iri.Repo)
      |> unique_constraint(:username)
    else
      changeset
    end
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      |> validate_length(:password, max: 72, count: :bytes)
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%Iri.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
