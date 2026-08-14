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

defmodule Iri.Library.Access do
  @moduledoc "Centralizes the account and game visibility rules for a signed-in scope."

  import Ecto.Query, warn: false

  alias Iri.Accounts.Scope
  alias Iri.Integrations.ProviderAccount
  alias Iri.InstancePolicy
  alias Iri.Library.{Game, GameSource}
  alias Iri.Repo

  @doc "Returns a query selecting provider-account IDs visible to the signed-in user."
  def account_ids(%Scope{user: user}) when not is_nil(user) do
    shared_policies =
      if InstancePolicy.account_shared_by_default?(),
        do: [:inherit, :everyone],
        else: [:everyone]

    from account in ProviderAccount,
      left_join: share in "provider_account_shares",
      on:
        field(share, :provider_account_id) == account.id and
          field(share, :user_id) == ^user.id,
      where:
        account.enabled and
          (account.sharing_policy in ^shared_policies or account.owner_user_id == ^user.id or
             not is_nil(field(share, :user_id))),
      distinct: true,
      select: account.id
  end

  @doc "Returns a query selecting canonical game IDs visible through accessible active libraries."
  def game_ids(%Scope{user: user} = scope) when not is_nil(user) do
    accessible_account_ids = account_ids(scope)

    from source in GameSource,
      join: item in assoc(source, :library_items),
      join: account in assoc(item, :provider_account),
      where:
        not item.hidden and is_nil(item.removed_at) and account.enabled and
          account.id in subquery(accessible_account_ids) and not is_nil(source.game_id),
      select: source.game_id,
      distinct: true
  end

  @doc "Returns whether a canonical game is accessible to the supplied scope."
  def game?(%Scope{user: user} = scope, game_id)
      when not is_nil(user) and is_integer(game_id) and game_id > 0 do
    account_ids = account_ids(scope)

    Repo.exists?(
      from game in Game,
        join: source in assoc(game, :sources),
        join: item in assoc(source, :library_items),
        where:
          game.id == ^game_id and not item.hidden and is_nil(item.removed_at) and
            item.provider_account_id in subquery(account_ids)
    )
  end

  def game?(_scope, _game_id), do: false
end
