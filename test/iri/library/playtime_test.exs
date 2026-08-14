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

defmodule Iri.Library.PlaytimeTest do
  use ExUnit.Case, async: true

  alias Iri.Accounts.User
  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.Playtime

  test "a user's own Steam account counts even without a chosen main account" do
    user = %User{id: 1, main_steam_account_id: nil, steam_id: nil}
    owned = %ProviderAccount{provider: :steam, owner_user_id: 1}

    assert Playtime.personal_account?(owned, user)
  end

  test "another user's Steam account never counts as the fallback" do
    user = %User{id: 1, main_steam_account_id: nil, steam_id: nil}
    shared = %ProviderAccount{provider: :steam, owner_user_id: 2}

    refute Playtime.personal_account?(shared, user)
  end

  test "the chosen main Steam account is honored over the fallback" do
    user = %User{id: 1, main_steam_account_id: 42, steam_id: nil}
    main = %ProviderAccount{id: 42, provider: :steam, owner_user_id: 1}
    other_owned = %ProviderAccount{id: 43, provider: :steam, owner_user_id: 1}

    assert Playtime.personal_account?(main, user)
    # With a main chosen, a different owned Steam account is not counted.
    refute Playtime.personal_account?(other_owned, user)
  end

  test "a linked Steam identity is matched by steam_id" do
    user = %User{id: 1, main_steam_account_id: nil, steam_id: "7656119"}
    linked = %ProviderAccount{provider: :steam, external_user_id: "7656119", owner_user_id: 2}

    assert Playtime.personal_account?(linked, user)
  end

  test "non-Steam accounts count when owned by the user" do
    user = %User{id: 1, main_steam_account_id: nil, steam_id: nil}
    gog = %ProviderAccount{provider: :gog, owner_user_id: 1}

    assert Playtime.personal_account?(gog, user)
    refute Playtime.personal_account?(%ProviderAccount{provider: :gog, owner_user_id: 2}, user)
  end
end
