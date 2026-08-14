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

defmodule Iri.AccountsTest do
  use Iri.DataCase

  alias Iri.Accounts

  import Iri.AccountsFixtures
  alias Iri.Accounts.{User, UserToken}
  alias Iri.Integrations.ProviderAccount

  describe "get_user_by_username_and_password/2" do
    test "does not return the user if the username does not exist" do
      refute Accounts.get_user_by_username_and_password("unknown", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture() |> set_password()
      refute Accounts.get_user_by_username_and_password(user.username, "invalid")
    end

    test "returns the user if the username and password are valid" do
      %{id: id} = user = user_fixture() |> set_password()

      assert %User{id: ^id} =
               Accounts.get_user_by_username_and_password(user.username, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(-1)
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "Steam identity" do
    test "creates one user for an imported Steam owner and claims that library" do
      account =
        %ProviderAccount{}
        |> ProviderAccount.changeset(%{
          provider: :steam,
          external_user_id: "76561198000000001",
          display_name: "Family Player"
        })
        |> Repo.insert!()

      assert {:ok, first} = Accounts.get_or_register_steam_user(account.external_user_id)
      assert first.steam_id == account.external_user_id
      assert first.username =~ "Family_Player"

      assert {:ok, second} = Accounts.get_or_register_steam_user(account.external_user_id)
      assert second.id == first.id
      assert Repo.reload!(account).owner_user_id == first.id
    end

    test "a verified Steam login takes an account over from whoever manually added it" do
      squatter = user_fixture()
      real_owner = user_fixture()

      account =
        %ProviderAccount{}
        |> ProviderAccount.changeset(%{
          provider: :steam,
          external_user_id: "76561198000000002",
          display_name: "Real Owner"
        })
        |> Ecto.Changeset.put_change(:owner_user_id, squatter.id)
        |> Repo.insert!()

      assert {:ok, linked} =
               Accounts.link_steam_identity(
                 Iri.Accounts.Scope.for_user(real_owner),
                 account.external_user_id
               )

      assert linked.steam_id == account.external_user_id

      reloaded = Repo.reload!(account) |> Repo.preload(:shared_users)
      assert reloaded.owner_user_id == real_owner.id
      assert Enum.map(reloaded.shared_users, & &1.id) == [squatter.id]
    end
  end

  describe "register_user/1" do
    setup do
      previous = Application.get_env(:iri, :mode)
      Application.put_env(:iri, :mode, :public)
      on_exit(fn -> Application.put_env(:iri, :mode, previous) end)
    end

    test "requires username to be set" do
      {:error, changeset} = Accounts.register_user(%{})

      assert %{username: ["can't be blank"]} = errors_on(changeset)
    end

    test "registers a local user with a password" do
      {:ok, user} = Accounts.register_user(valid_user_attributes())
      assert is_binary(user.hashed_password)
      assert is_nil(user.password)
    end

    test "makes the first local user an admin and later users viewers" do
      {:ok, admin} = Accounts.register_user(valid_user_attributes())
      {:ok, viewer} = Accounts.register_user(valid_user_attributes())

      assert admin.role == :admin
      assert viewer.role == :viewer
    end
  end

  test "family mode closes registration after the first account" do
    previous = Application.get_env(:iri, :mode)
    Application.put_env(:iri, :mode, :family)
    on_exit(fn -> Application.put_env(:iri, :mode, previous) end)

    assert {:ok, %{role: :admin}} = Accounts.register_user(valid_user_attributes())
    assert {:error, :registration_closed} = Accounts.register_user(valid_user_attributes())
  end

  describe "change_user_password/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(
          %User{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, %{
          password: "short",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 6 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_user_password(user, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, {user, expired_tokens}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(user.password)
      assert Accounts.get_user_by_username_and_password(user.username, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_, _}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id
        })
      end
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert token_inserted_at != nil
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: dt])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "inspect/2 for the User module" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end
end
