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

defmodule Iri.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Iri.Repo

  alias Iri.Accounts.{Scope, User, UserToken}
  alias Iri.Integrations.{ProviderAccount, ProviderAccountShare}
  alias Iri.InstancePolicy

  ## Database getters

  def get_user_by_username_and_password(username, password)
      when is_binary(username) and is_binary(password) do
    user = Repo.get_by(User, username: String.trim(username))
    if User.valid_password?(user, password), do: user
  end

  def list_users(%Scope{} = scope) do
    if Scope.admin?(scope) do
      {:ok, Repo.all(from user in User, order_by: [asc: user.username, asc: user.id])}
    else
      {:error, :unauthorized}
    end
  end

  def list_shareable_users(%Scope{user: %User{}}) do
    {:ok, Repo.all(from user in User, order_by: [asc: user.username, asc: user.id])}
  end

  def list_shareable_users(_scope), do: {:error, :unauthorized}

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    if registration_open?() do
      Repo.transact(
        fn ->
          role = if Repo.exists?(User), do: :viewer, else: :admin

          %User{}
          |> User.registration_changeset(attrs)
          |> Ecto.Changeset.put_change(:role, role)
          |> Repo.insert()
        end,
        mode: :immediate
      )
    else
      {:error, :registration_closed}
    end
  end

  def first_user_registration?, do: not Repo.exists?(User)

  def registration_open? do
    first_user_registration?() or InstancePolicy.public_registration?()
  end

  def create_user(%Scope{} = scope, attrs) do
    if Scope.admin?(scope) do
      %User{}
      |> User.registration_changeset(attrs)
      |> Ecto.Changeset.put_change(:role, :viewer)
      |> Repo.insert()
    else
      {:error, :unauthorized}
    end
  end

  def change_user_registration(user, attrs \\ %{}, opts \\ []) do
    User.registration_changeset(user, attrs, opts)
  end

  def change_user_username(user, attrs \\ %{}, opts \\ []) do
    User.username_changeset(user, attrs, opts)
  end

  def update_user_username(%User{} = user, attrs) do
    user
    |> User.username_changeset(attrs)
    |> Repo.update()
  end

  def get_or_register_steam_user(steam_id) when is_binary(steam_id) do
    Repo.transact(fn ->
      case Repo.get_by(User, steam_id: steam_id) do
        %User{} = user ->
          claim_steam_library(user, steam_id)
          {:ok, Repo.reload!(user)}

        nil ->
          if registration_open?() do
            display_name =
              case Repo.get_by(ProviderAccount, provider: :steam, external_user_id: steam_id) do
                %ProviderAccount{display_name: name} when is_binary(name) -> name
                _account -> "steam"
              end

            role = if Repo.exists?(User), do: :viewer, else: :admin
            username = available_steam_username(display_name, steam_id)

            with {:ok, user} <-
                   %User{}
                   |> User.steam_changeset(steam_id, username)
                   |> Ecto.Changeset.put_change(:role, role)
                   |> Repo.insert() do
              claim_steam_library(user, steam_id)
              {:ok, Repo.reload!(user)}
            end
          else
            {:error, :registration_closed}
          end
      end
    end)
  end

  def link_steam_identity(%Scope{user: %User{} = user}, steam_id) when is_binary(steam_id) do
    case Repo.get_by(User, steam_id: steam_id) do
      nil ->
        Repo.transact(fn ->
          with {:ok, user} <-
                 user
                 |> Ecto.Changeset.change(steam_id: steam_id)
                 |> Ecto.Changeset.unique_constraint(:steam_id)
                 |> Repo.update() do
            claim_steam_library(user, steam_id)
            {:ok, Repo.reload!(user)}
          end
        end)

      %User{id: id} when id == user.id ->
        claim_steam_library(user, steam_id)
        {:ok, Repo.reload!(user)}

      %User{} ->
        {:error, :steam_identity_taken}
    end
  end

  def link_steam_identity(_scope, _steam_id), do: {:error, :unauthorized}

  @doc "Selects the linked Steam library used for this user's personal playtime."
  def set_main_steam_account(%Scope{user: %User{} = user}, account_id) do
    with account_id when is_integer(account_id) and account_id > 0 <- integer_id(account_id),
         %ProviderAccount{} = account <- linked_steam_account(user.id, account_id) do
      user
      |> User.main_steam_account_changeset(account.id)
      |> Repo.update()
    else
      _value -> {:error, :not_found}
    end
  end

  def set_main_steam_account(_scope, _account_id), do: {:error, :unauthorized}

  @doc "Selects the sole linked Steam account when the user has not chosen one yet."
  def ensure_main_steam_account(%User{main_steam_account_id: account_id} = user)
      when is_integer(account_id) and account_id > 0,
      do: {:ok, user}

  def ensure_main_steam_account(%User{} = user) do
    case linked_steam_account_ids(user.id) do
      [account_id] ->
        user
        |> User.main_steam_account_changeset(account_id)
        |> Repo.update()

      _accounts ->
        {:ok, user}
    end
  end

  ## Settings

  def change_user_sensitive_media(%User{} = user, attrs \\ %{}) do
    User.sensitive_media_changeset(user, attrs)
  end

  def update_user_sensitive_media(%Scope{user: %User{} = user}, attrs) do
    user
    |> User.sensitive_media_changeset(attrs)
    |> Repo.update()
  end

  def update_user_sensitive_media(_scope, _attrs), do: {:error, :unauthorized}

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Iri.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc "Deletes a signed session token."
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  # Runs only after Steam OpenID proved control of the account, so the login
  # takes the provider account over even when someone else had added it to
  # their library (public-instance squatting). The previous owner keeps
  # access through an explicit share.
  defp claim_steam_library(user, steam_id) do
    account = Repo.get_by(ProviderAccount, provider: :steam, external_user_id: steam_id)

    result =
      case account do
        nil ->
          :ok

        %ProviderAccount{owner_user_id: owner_id} when owner_id == user.id ->
          :ok

        %ProviderAccount{owner_user_id: nil} = account ->
          {1, _} =
            from(current in ProviderAccount, where: current.id == ^account.id)
            |> Repo.update_all(set: [owner_user_id: user.id])

          :ok

        %ProviderAccount{owner_user_id: previous_owner_id} = account ->
          {1, _} =
            from(current in ProviderAccount, where: current.id == ^account.id)
            |> Repo.update_all(set: [owner_user_id: user.id])

          Repo.insert_all(
            Iri.Integrations.ProviderAccountShare,
            [
              %{
                provider_account_id: account.id,
                user_id: previous_owner_id,
                linked: true,
                inserted_at: DateTime.utc_now(:second)
              }
            ],
            on_conflict: [set: [linked: true]],
            conflict_target: [:provider_account_id, :user_id]
          )

          :ok
      end

    if account do
      user
      |> User.main_steam_account_changeset(account.id)
      |> Repo.update!()
    end

    result
  end

  defp linked_steam_account(user_id, account_id) do
    Repo.one(
      from account in ProviderAccount,
        left_join: share in ProviderAccountShare,
        on:
          share.provider_account_id == account.id and share.user_id == ^user_id and share.linked,
        where:
          account.id == ^account_id and account.provider == :steam and account.enabled and
            (account.owner_user_id == ^user_id or not is_nil(share.user_id)),
        limit: 1
    )
  end

  defp linked_steam_account_ids(user_id) do
    Repo.all(
      from account in ProviderAccount,
        left_join: share in ProviderAccountShare,
        on:
          share.provider_account_id == account.id and share.user_id == ^user_id and share.linked,
        where:
          account.provider == :steam and account.enabled and
            (account.owner_user_id == ^user_id or not is_nil(share.user_id)),
        distinct: true,
        order_by: [asc: account.id],
        select: account.id
    )
  end

  defp integer_id(value) when is_integer(value), do: value

  defp integer_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _error -> nil
    end
  end

  defp integer_id(_value), do: nil

  defp available_steam_username(display_name, steam_id) do
    base =
      display_name
      |> String.trim()
      |> String.replace(~r/[^\p{L}\p{N}_.-]+/u, "_")
      |> String.trim("_.-")
      |> case do
        value when byte_size(value) >= 2 -> String.slice(value, 0, 30)
        _value -> "steam"
      end

    suffix = String.slice(steam_id, -6, 6)
    candidate = "#{base}_#{suffix}"

    if Repo.exists?(from user in User, where: user.username == ^candidate) do
      "steam_#{steam_id}"
    else
      candidate
    end
  end
end
