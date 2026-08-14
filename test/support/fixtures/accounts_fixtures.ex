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
#

defmodule Iri.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Iri.Accounts` context.
  """

  import Ecto.Query

  alias Iri.Accounts
  alias Iri.Accounts.Scope

  def unique_username, do: "user_#{System.unique_integer([:positive])}"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      username: unique_username(),
      password: valid_user_password(),
      password_confirmation: valid_user_password()
    })
  end

  def user_fixture(attrs \\ %{}) do
    attrs = valid_user_attributes(attrs)

    role = if Iri.Repo.exists?(Accounts.User), do: :viewer, else: :admin

    {:ok, user} =
      %Accounts.User{}
      |> Accounts.User.registration_changeset(attrs)
      |> Ecto.Changeset.put_change(:role, role)
      |> Iri.Repo.insert()

    user
  end

  def admin_user_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)
    user |> Ecto.Changeset.change(role: :admin) |> Iri.Repo.update!()
  end

  def viewer_user_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)
    user |> Ecto.Changeset.change(role: :viewer) |> Iri.Repo.update!()
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Iri.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt]
    )
  end
end
