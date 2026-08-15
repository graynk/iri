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

defmodule Iri.DemoTest do
  use Iri.DataCase, async: false

  alias Iri.Accounts.User
  alias Iri.Demo

  test "loads the fixed demo snapshot identity as an in-memory viewer" do
    admin =
      Repo.insert!(%User{
        username: "demo",
        hashed_password: Bcrypt.hash_pwd_salt("demo"),
        role: :admin
      })

    assert User.valid_password?(admin, "demo")

    start_supervised!(Demo)

    scope = Demo.scope()
    assert scope.user.id == admin.id
    assert scope.user.username == "demo"
    assert scope.user.role == :viewer
    assert scope.user.hashed_password == nil
    assert scope.role == :viewer

    assert Repo.get!(User, admin.id).role == :admin
    assert Repo.get!(User, admin.id).hashed_password != nil
  end

  test "refuses to start without the fixed demo snapshot identity" do
    Process.flag(:trap_exit, true)

    assert {:error, reason} = Demo.start_link(name: :missing_demo_identity)
    assert reason =~ ~s(required demo user "demo" does not exist in the snapshot)
  end
end
