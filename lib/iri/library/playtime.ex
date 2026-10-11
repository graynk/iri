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
  Playtime attribution and the one clamped total computation.

  Playtime is always the *viewer's own* — a user sees the hours from their own
  Steam account (the one they play on), never another user's, even when the
  game itself lives in a library shared with them.

  `total_minutes/2` is the single place that combines the viewer's store
  hours with their manual offset, clamped at zero. Every read path in the
  web layer must compute its total through it so a below-zero total can
  never reach a label, a sort, or an export.
  """

  import Ecto.Query

  alias Iri.Accounts.User
  alias Iri.Integrations.ProviderAccount

  # Stores that report hours of their own. Their sync always wins: a provider
  # moved onto this list overwrites manual values on its next import.
  @self_reported_providers [:steam, :gog, :xbox]

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

  @doc "Whether a store brings its own playtime, making the field read-only."
  def self_reported?(provider), do: provider in @self_reported_providers

  @doc """
  The viewer's total playtime, in minutes, for a game.

  `items` are the viewer's own visible library items for the game (already
  filtered through `personal_account?/2` and the usual hidden/removed/enabled
  filters); `offset_minutes` is their manual offset (0 when unset). Store
  hours sum across stores, the offset is added on top, and the result is
  clamped at zero — a below-zero sum can never be returned.
  """
  @spec total_minutes([map()], integer()) :: non_neg_integer()
  def total_minutes(items, offset_minutes) when is_list(items) and is_integer(offset_minutes) do
    store_minutes =
      items
      |> Enum.map(&(&1.playtime_minutes || 0))
      |> Enum.sum()

    max(0, store_minutes + offset_minutes)
  end
end
