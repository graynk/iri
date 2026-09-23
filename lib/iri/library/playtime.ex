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

  alias Iri.Accounts.{Scope, User}
  alias Iri.Integrations.{Custom, ProviderAccount}
  alias Iri.Library.{Access, GameSource, LibraryItem}
  alias Iri.Repo

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
  Whether the viewer may type their own hours onto this library item.

  Pure and in-memory, so a LiveView can ask about an already-preloaded
  `item.provider_account` without a second query.
  """
  def editable?(%ProviderAccount{} = account, %User{} = user) do
    personal_account?(account, user) and not self_reported?(account.provider)
  end

  @doc """
  Records the viewer's own playtime for an accessible game.

  Writes every editable personal item for the game, so the value stays coherent
  with the `max()` aggregation readers use when the same game is owned on two
  such stores.
  """
  def set_minutes(%Scope{user: %User{} = user} = scope, game_id, minutes)
      when is_integer(game_id) and game_id > 0 and is_integer(minutes) and minutes >= 0 do
    if Access.game?(scope, game_id) do
      case editable_item_ids(user, game_id) do
        [] ->
          case create_personal_custom_item(scope, user, game_id) do
            {:ok, _item} ->
              case editable_item_ids(user, game_id) do
                [] -> {:error, :not_editable}
                item_ids -> update_minutes(item_ids, minutes)
              end

            {:error, :not_custom} ->
              {:error, :not_editable}

            {:error, reason} ->
              {:error, reason}
          end

        item_ids ->
          update_minutes(item_ids, minutes)
      end
    else
      {:error, :not_found}
    end
  end

  def set_minutes(_scope, _game_id, _minutes), do: {:error, :not_found}

  defp update_minutes(item_ids, minutes) do
    now = DateTime.utc_now(:second)

    Repo.update_all(
      from(item in LibraryItem, where: item.id in ^item_ids),
      set: [playtime_minutes: minutes, updated_at: now]
    )

    {:ok, minutes}
  end

  defp create_personal_custom_item(scope, user, game_id) do
    accessible_account_ids = Access.account_ids(scope)

    source_id =
      Repo.one(
        from source in GameSource,
          join: item in assoc(source, :library_items),
          join: account in assoc(item, :provider_account),
          where:
            source.game_id == ^game_id and source.provider == :igdb and
              account.provider == :custom and account.enabled and not item.hidden and
              is_nil(item.removed_at) and account.id in subquery(accessible_account_ids),
          select: source.id,
          limit: 1
      )

    if source_id do
      Repo.transact(fn ->
        with {:ok, account} <- Custom.ensure_account(user) do
          item =
            Repo.get_by(LibraryItem,
              provider_account_id: account.id,
              game_source_id: source_id
            ) || %LibraryItem{}

          item
          |> LibraryItem.changeset(%{
            provider_account_id: account.id,
            game_source_id: source_id,
            relationship: :manual,
            hidden: false,
            removed_at: nil
          })
          |> Repo.insert_or_update()
        end
      end)
    else
      {:error, :not_custom}
    end
  end

  defp editable_item_ids(user, game_id) do
    personal_account_filter = personal_account_filter(user)

    Repo.all(
      from item in LibraryItem,
        join: source in assoc(item, :game_source),
        join: account in assoc(item, :provider_account),
        as: :account,
        where: ^personal_account_filter,
        where:
          source.game_id == ^game_id and not item.hidden and is_nil(item.removed_at) and
            account.enabled and account.provider not in ^@self_reported_providers,
        select: item.id
    )
  end
end
