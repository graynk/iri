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

defmodule Iri.Integrations.Steam.ManualLibrary do
  @moduledoc "Adds Steam licenses that are missing from Steam's public owned-games response."

  import Ecto.Query, warn: false

  alias Iri.Accounts.{Scope, User}
  alias Iri.Integrations.{ProviderAccount, ProviderAccountShare}
  alias Iri.Integrations.Steam.StoreClient
  alias Iri.Library.{GameSource, LibraryItem, Title}
  alias Iri.Repo
  alias Iri.Sync.Scheduler

  def parse_app_id(value) when is_binary(value) do
    value = String.trim(value)

    digits =
      cond do
        Regex.match?(~r/^\d+$/, value) ->
          value

        match = Regex.run(~r{^https?://store\.steampowered\.com/app/(\d+)(?:/|$)}i, value) ->
          Enum.at(match, 1)

        true ->
          nil
      end

    case digits && Integer.parse(digits) do
      {id, ""} when id > 0 -> {:ok, Integer.to_string(id)}
      _invalid -> {:error, :invalid_app_id}
    end
  end

  def parse_app_id(_value), do: {:error, :invalid_app_id}

  def add(scope, input, options \\ [])

  def add(%Scope{user: %User{} = user}, input, options) do
    with {:ok, app_id} <- parse_app_id(input),
         %ProviderAccount{} = account <- personal_steam_account(user),
         client = Keyword.get(options, :client, StoreClient),
         {:ok, details} <-
           client.fetch_app_details(app_id, Keyword.get(options, :client_options, [])),
         :ok <- validate_catalog_kind(details.catalog_kind),
         {:ok, result} <- persist(account, details) do
      maybe_enqueue_enrichment(result.status, options)
      {:ok, result}
    else
      nil -> {:error, :steam_account_required}
      error -> error
    end
  end

  def add(_scope, _input, _options), do: {:error, :unauthorized}

  def remove(%Scope{user: %User{id: user_id}}, source_id) do
    with source_id when is_integer(source_id) and source_id > 0 <- integer_id(source_id),
         %LibraryItem{} = item <- manual_item(user_id, source_id) do
      Repo.transact_with_busy_retry(
        fn ->
          source_id = item.game_source_id
          {:ok, _item} = Repo.delete(item)

          if not Repo.exists?(
               from current in LibraryItem, where: current.game_source_id == ^source_id
             ) do
            Repo.delete_all(from source in GameSource, where: source.id == ^source_id)
          end

          {:ok, %{removed: 1}}
        end,
        mode: :immediate
      )
    else
      _missing -> {:error, :not_found}
    end
  end

  def remove(_scope, _source_id), do: {:error, :unauthorized}

  def manual_item?(%LibraryItem{manually_added: manually_added}), do: manually_added

  def manual_item?(_item), do: false

  defp persist(account, details) do
    Repo.transact_with_busy_retry(
      fn ->
        source =
          Repo.get_by(GameSource, provider: :steam, external_id: details.app_id) ||
            %GameSource{}

        {:ok, source} =
          source
          |> GameSource.changeset(%{
            provider: :steam,
            external_id: details.app_id,
            source_title: details.title,
            normalized_source_title: Title.normalize(details.title),
            source_url: details.source_url,
            metadata_snapshot: details.metadata_snapshot,
            catalog_kind: details.catalog_kind
          })
          |> Repo.insert_or_update()

        item =
          Repo.get_by(LibraryItem,
            provider_account_id: account.id,
            game_source_id: source.id
          ) || %LibraryItem{}

        status =
          if item.id && is_nil(item.removed_at), do: :already_owned, else: :added

        {:ok, item} =
          item
          |> LibraryItem.changeset(%{
            provider_account_id: account.id,
            game_source_id: source.id,
            relationship: :owned,
            hidden: false,
            manually_added: true,
            removed_at: nil
          })
          |> Repo.insert_or_update()

        {:ok, %{status: status, source: source, item: item, account: account}}
      end,
      mode: :immediate
    )
  end

  defp personal_steam_account(%User{id: user_id, main_steam_account_id: account_id})
       when is_integer(account_id) and account_id > 0 do
    linked_steam_account(user_id, account_id)
  end

  defp personal_steam_account(%User{id: user_id}) do
    case linked_steam_accounts(user_id) do
      [account] -> account
      _accounts -> nil
    end
  end

  defp linked_steam_account(user_id, account_id) do
    linked_steam_accounts(user_id)
    |> Enum.find(&(&1.id == account_id))
  end

  defp linked_steam_accounts(user_id) do
    Repo.all(
      from account in ProviderAccount,
        left_join: share in ProviderAccountShare,
        on:
          share.provider_account_id == account.id and share.user_id == ^user_id and share.linked,
        where:
          account.provider == :steam and account.enabled and
            (account.owner_user_id == ^user_id or not is_nil(share.user_id)),
        distinct: true,
        order_by: [asc: account.id]
    )
  end

  defp manual_item(user_id, source_id) do
    Repo.one(
      from item in LibraryItem,
        join: account in assoc(item, :provider_account),
        left_join: share in ProviderAccountShare,
        on:
          share.provider_account_id == account.id and share.user_id == ^user_id and share.linked,
        where:
          item.game_source_id == ^source_id and account.provider == :steam and
            (account.owner_user_id == ^user_id or not is_nil(share.user_id)) and
            item.manually_added,
        limit: 1
    )
  end

  defp validate_catalog_kind(kind) when kind in [nil, "game", "unknown"], do: :ok
  defp validate_catalog_kind(_kind), do: {:error, :not_a_game}

  defp maybe_enqueue_enrichment(:added, options) do
    if Keyword.get(options, :enqueue_enrichment, true) do
      _result = Scheduler.enqueue_library_enrichment(compatibility: true)
    end

    :ok
  end

  defp maybe_enqueue_enrichment(_status, _options), do: :ok

  defp integer_id(value) when is_integer(value), do: value

  defp integer_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _invalid -> nil
    end
  end

  defp integer_id(_value), do: nil
end
