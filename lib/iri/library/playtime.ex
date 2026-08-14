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

defmodule Iri.Library.Playtime do
  @moduledoc """
  Identifies which provider account a game's playtime "belongs to" for a user.

  Playtime is always the *viewer's own* — a user sees the hours from their own
  Steam account (the one they play on), never another user's, even when the
  game itself lives in a library shared with them.
  """

  import Ecto.Query

  alias Iri.Accounts.User
  alias Iri.Integrations.ProviderAccount

  @doc """
  Query filter (bound as `account`) selecting the accounts whose playtime counts
  as the given user's own: their chosen main Steam account (or, absent that,
  their linked Steam identity, or any Steam account they own), plus every
  non-Steam account they own.
  """
  def personal_account_filter(%User{id: user_id, main_steam_account_id: account_id})
      when is_integer(account_id) and account_id > 0 do
    dynamic(
      [account: account],
      (account.provider == :steam and account.id == ^account_id) or
        (account.provider != :steam and account.owner_user_id == ^user_id)
    )
  end

  def personal_account_filter(%User{id: user_id, steam_id: steam_id})
      when is_binary(steam_id) and steam_id != "" do
    dynamic(
      [account: account],
      (account.provider == :steam and account.external_user_id == ^steam_id) or
        (account.provider != :steam and account.owner_user_id == ^user_id)
    )
  end

  def personal_account_filter(%User{id: user_id}) do
    dynamic([account: account], account.owner_user_id == ^user_id)
  end

  def personal_account?(
        %ProviderAccount{provider: :steam, id: account_id},
        %User{main_steam_account_id: account_id}
      )
      when is_integer(account_id) and account_id > 0,
      do: true

  def personal_account?(
        %ProviderAccount{provider: :steam, external_user_id: steam_id},
        %User{main_steam_account_id: nil, steam_id: steam_id}
      )
      when is_binary(steam_id) and steam_id != "",
      do: true

  # Fallback for a user with no chosen main Steam account and no linked Steam
  # identity: a Steam account they own counts as theirs.
  def personal_account?(
        %ProviderAccount{provider: :steam, owner_user_id: user_id},
        %User{id: user_id, main_steam_account_id: nil, steam_id: nil}
      ),
      do: true

  def personal_account?(%ProviderAccount{provider: :steam}, %User{}), do: false

  def personal_account?(
        %ProviderAccount{provider: provider, owner_user_id: user_id},
        %User{id: user_id}
      )
      when provider != :steam,
      do: true

  def personal_account?(%ProviderAccount{}, %User{}), do: false
end
