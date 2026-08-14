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

defmodule Iri.Integrations do
  @moduledoc "User-owned provider account management and runtime key status."

  import Ecto.Query, warn: false

  alias Iri.Accounts
  alias Iri.Accounts.{Scope, User}

  alias Iri.Integrations.{
    GOGConnectionForm,
    ProviderAccount,
    ProviderAccountShare,
    SteamConnectionForm,
    XboxConnectionForm
  }

  alias Iri.Integrations.GOG.Client, as: GOGClient
  alias Iri.Integrations.IGDB.TokenManager
  alias Iri.Integrations.Steam.Client, as: SteamClient
  alias Iri.Integrations.Xbox.Client, as: XboxClient
  alias Iri.Library
  alias Iri.Params
  alias Iri.Repo

  @doc "Returns provider accounts owned by or explicitly linked to the signed-in user."
  def list_provider_accounts(%Scope{user: %User{id: user_id}}) do
    accounts =
      ProviderAccount
      |> join(:left, [account], share in ProviderAccountShare,
        on: share.provider_account_id == account.id and share.user_id == ^user_id and share.linked
      )
      |> where([account, share], account.owner_user_id == ^user_id or not is_nil(share.user_id))
      |> distinct(true)
      |> order_by([account], asc: account.provider, asc: account.display_name, asc: account.id)
      |> preload([:owner_user, :shared_users])
      |> Repo.all()

    {:ok, accounts}
  end

  def list_provider_accounts(_scope), do: {:error, :unauthorized}

  @doc "Updates the owner's sharing policy and explicitly shared users for one provider account."
  def update_provider_account_access(%Scope{} = scope, id, attrs) do
    with %ProviderAccount{} = account <- owned_account(scope, id),
         {:ok, sharing_policy} <-
           sharing_policy_value(Map.get(attrs, "sharing_policy")) do
      user_ids = valid_user_ids(Map.get(attrs, "shared_user_ids", []))

      Repo.transact(fn ->
        with {:ok, account} <-
               account
               |> ProviderAccount.changeset(%{sharing_policy: sharing_policy})
               |> Repo.update() do
          Repo.delete_all(
            from share in ProviderAccountShare,
              where: share.provider_account_id == ^account.id and not share.linked
          )

          now = DateTime.utc_now(:second)

          Repo.insert_all(
            ProviderAccountShare,
            user_ids
            |> Enum.reject(&(&1 == account.owner_user_id))
            |> Enum.map(fn user_id ->
              %{
                provider_account_id: account.id,
                user_id: user_id,
                linked: false,
                inserted_at: now
              }
            end),
            on_conflict: :nothing
          )

          {:ok, Repo.preload(account, [:owner_user, :shared_users], force: true)}
        end
      end)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Deletes a provider account when its owner is not currently syncing it."
  def delete_provider_account(%Scope{} = scope, id) do
    with %ProviderAccount{} = account <- owned_account(scope, id),
         false <- active_sync?(account.id) do
      Repo.transact(fn ->
        with {:ok, account} <- Repo.delete(account),
             {:ok, pruned} <- Library.prune_orphaned_games() do
          {:ok, {account, pruned}}
        end
      end)
    else
      nil -> {:error, :not_found}
      true -> {:error, :sync_in_progress}
    end
  end

  @doc "Creates a provider account owned by the signed-in user."
  def create_provider_account(%Scope{user: %User{} = user}, attrs) do
    %ProviderAccount{}
    |> ProviderAccount.changeset(attrs)
    |> Ecto.Changeset.put_change(:owner_user_id, user.id)
    |> Repo.insert()
  end

  def create_provider_account(_scope, _attrs), do: {:error, :unauthorized}

  @doc "Validates a public Steam profile and creates or links its provider account."
  def connect_steam(scope, attrs, options \\ [])

  def connect_steam(%Scope{user: %User{} = user}, attrs, options) do
    with %Ecto.Changeset{valid?: true} = form_changeset <-
           SteamConnectionForm.changeset(%SteamConnectionForm{}, attrs),
         {:ok, api_key} <- steam_api_key(),
         client <- Keyword.get(options, :client, configured_client(:steam_client, SteamClient)),
         client_options <- Keyword.get(options, :client_options, []),
         {:ok, setup} <-
           client.validate_setup(
             Ecto.Changeset.get_field(form_changeset, :profile),
             api_key,
             client_options
           ) do
      persist_steam_account(setup, user)
    else
      %Ecto.Changeset{} = changeset -> {:error, changeset}
      error -> error
    end
  end

  def connect_steam(_scope, _attrs, _options), do: {:error, :unauthorized}

  @doc "Validates a public GOG profile and creates or links its provider account."
  def connect_gog(scope, attrs, options \\ [])

  def connect_gog(%Scope{user: %User{} = user}, attrs, options) do
    with %Ecto.Changeset{valid?: true} = form_changeset <-
           GOGConnectionForm.changeset(%GOGConnectionForm{}, attrs),
         client <- Keyword.get(options, :client, configured_client(:gog_client, GOGClient)),
         client_options <- Keyword.get(options, :client_options, []),
         profile <- Ecto.Changeset.get_field(form_changeset, :profile),
         {:ok, preview} <- client.validate_profile(profile, client_options) do
      persist_gog_account(preview, user)
    else
      %Ecto.Changeset{} = changeset -> {:error, changeset}
      error -> error
    end
  end

  def connect_gog(_scope, _attrs, _options), do: {:error, :unauthorized}

  @doc "Resolves an Xbox gamertag and creates or links its provider account."
  def connect_xbox(scope, attrs, options \\ [])

  def connect_xbox(%Scope{user: %User{} = user}, attrs, options) do
    with %Ecto.Changeset{valid?: true} = form_changeset <-
           XboxConnectionForm.changeset(%XboxConnectionForm{}, attrs),
         {:ok, api_key} <- openxbl_api_key(),
         client <- Keyword.get(options, :client, configured_client(:xbox_client, XboxClient)),
         client_options <- Keyword.get(options, :client_options, []),
         {:ok, profile} <-
           client.resolve_profile(
             Ecto.Changeset.get_field(form_changeset, :gamertag),
             api_key,
             client_options
           ) do
      persist_xbox_account(profile, user)
    else
      %Ecto.Changeset{} = changeset -> {:error, changeset}
      error -> error
    end
  end

  def connect_xbox(_scope, _attrs, _options), do: {:error, :unauthorized}

  @doc "Reports whether the server has a usable Steam Web API key."
  def steam_api_key_configured?(%Scope{user: %User{}}),
    do: {:ok, match?({:ok, _api_key}, steam_api_key())}

  def steam_api_key_configured?(_scope), do: {:error, :unauthorized}

  @doc "Reports whether the server has an OpenXBL key for Xbox imports."
  def openxbl_configured?(%Scope{user: %User{}}),
    do: {:ok, match?({:ok, _api_key}, openxbl_api_key())}

  def openxbl_configured?(_scope), do: {:error, :unauthorized}

  @doc "Reports whether IGDB credentials are configured."
  def igdb_configured?(%Scope{user: %User{}}), do: {:ok, TokenManager.configured?()}
  def igdb_configured?(_scope), do: {:error, :unauthorized}

  @doc "Returns the server's Steam API key for a background sync."
  def steam_credentials_for_sync do
    with {:ok, api_key} <- steam_api_key(), do: {:ok, %{"api_key" => api_key}}
  end

  @doc "Returns the server's OpenXBL key for an Xbox background sync."
  def openxbl_credentials_for_sync(%ProviderAccount{provider: :xbox}) do
    with {:ok, key} <- openxbl_api_key(), do: {:ok, {key, []}}
  end

  def openxbl_credentials_for_sync(_account), do: {:error, :not_an_xbox_account}

  @doc "Authenticates the configured IGDB client for a background metadata operation."
  def igdb_credentials_for_sync(
        client \\ Application.get_env(:iri, :igdb_client, Iri.Integrations.IGDB.Client),
        options \\ []
      ) do
    TokenManager.credentials(client, options)
  end

  defp persist_steam_account(setup, user) do
    Repo.transact(fn ->
      account =
        Repo.get_by(ProviderAccount, provider: :steam, external_user_id: setup.steamid) ||
          %ProviderAccount{}

      result =
        if account.owner_user_id not in [nil, user.id] do
          follow_account(account, user, %{game_count: setup.game_count})
        else
          attrs = %{
            provider: :steam,
            external_user_id: setup.steamid,
            display_name: setup.display_name
          }

          with {:ok, account} <-
                 account
                 |> ProviderAccount.changeset(attrs)
                 |> Ecto.Changeset.put_change(:owner_user_id, user.id)
                 |> Ecto.Changeset.put_change(:sync_status, "validated")
                 |> Repo.insert_or_update() do
            {:ok,
             %{
               account: Repo.preload(account, [:owner_user, :shared_users]),
               game_count: setup.game_count
             }}
          end
        end

      with {:ok, details} <- result,
           {:ok, user} <- Accounts.ensure_main_steam_account(user) do
        {:ok, Map.put(details, :user, user)}
      end
    end)
  end

  # Whoever connects an account first owns and manages it. Later connectors
  # follow the same imported library instead of duplicating it; each user may
  # independently select that account as their personal playtime source.
  defp follow_account(account, user, extra) do
    Repo.insert_all(
      ProviderAccountShare,
      [
        %{
          provider_account_id: account.id,
          user_id: user.id,
          linked: true,
          inserted_at: DateTime.utc_now(:second)
        }
      ],
      on_conflict: [set: [linked: true]],
      conflict_target: [:provider_account_id, :user_id]
    )

    result =
      Map.merge(extra, %{
        account: Repo.preload(account, [:owner_user, :shared_users], force: true),
        followed: true
      })

    {:ok, result}
  end

  defp persist_gog_account(preview, user) do
    Repo.transact(fn ->
      account =
        Repo.get_by(ProviderAccount, provider: :gog, external_user_id: preview.username) ||
          %ProviderAccount{}

      if account.owner_user_id not in [nil, user.id] do
        follow_account(account, user, %{game_count: preview.total})
      else
        attrs = %{
          provider: :gog,
          external_user_id: preview.username,
          display_name: preview.display_name
        }

        with {:ok, account} <-
               account
               |> ProviderAccount.changeset(attrs)
               |> Ecto.Changeset.put_change(:owner_user_id, user.id)
               |> Ecto.Changeset.put_change(:sync_status, "validated")
               |> Repo.insert_or_update() do
          {:ok,
           %{
             account: Repo.preload(account, [:owner_user, :shared_users]),
             game_count: preview.total
           }}
        end
      end
    end)
  end

  defp persist_xbox_account(profile, user) do
    Repo.transact(fn ->
      account =
        Repo.get_by(ProviderAccount, provider: :xbox, external_user_id: profile.xuid) ||
          %ProviderAccount{}

      if account.owner_user_id not in [nil, user.id] do
        follow_account(account, user, %{})
      else
        # Show the suffix-qualified tag so connecting the wrong same-named
        # account is visible in settings.
        display_name = Map.get(profile, :unique_gamertag) || profile.gamertag

        attrs = %{
          provider: :xbox,
          external_user_id: profile.xuid,
          display_name: display_name
        }

        with {:ok, account} <-
               account
               |> ProviderAccount.changeset(attrs)
               |> Ecto.Changeset.put_change(:owner_user_id, user.id)
               |> Ecto.Changeset.put_change(:sync_status, "validated")
               |> Repo.insert_or_update() do
          {:ok, %{account: Repo.preload(account, [:owner_user, :shared_users])}}
        end
      end
    end)
  end

  defp owned_account(%Scope{user: %User{id: user_id}}, id) do
    with id when not is_nil(id) <- Params.positive_integer(id) do
      case Repo.get(ProviderAccount, id) do
        %ProviderAccount{owner_user_id: owner_id} = account when owner_id == user_id -> account
        %ProviderAccount{owner_user_id: nil} = account -> account
        _account -> nil
      end
    end
  end

  defp owned_account(_scope, _id), do: nil

  defp steam_api_key do
    case Application.get_env(:iri, :steam_web_api_key) do
      api_key when is_binary(api_key) ->
        api_key = String.trim(api_key)

        if Regex.match?(~r/^[0-9a-fA-F]{32}$/, api_key),
          do: {:ok, api_key},
          else: {:error, :invalid_steam_api_key}

      _value ->
        {:error, :not_configured}
    end
  end

  defp openxbl_api_key do
    case Application.get_env(:iri, :openxbl_api_key) do
      api_key when is_binary(api_key) and byte_size(api_key) > 0 -> {:ok, String.trim(api_key)}
      _value -> {:error, :not_configured}
    end
  end

  defp sharing_policy_value(value) when value in ["inherit", :inherit], do: {:ok, :inherit}
  defp sharing_policy_value(value) when value in ["everyone", :everyone], do: {:ok, :everyone}

  defp sharing_policy_value(value) when value in ["selected_users", :selected_users],
    do: {:ok, :selected_users}

  defp sharing_policy_value(_value), do: {:error, :invalid_sharing_policy}

  defp valid_user_ids(values) do
    ids =
      values
      |> List.wrap()
      |> Enum.map(&Params.positive_integer/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Repo.all(from user in User, where: user.id in ^ids, select: user.id)
  end

  defp active_sync?(account_id) do
    Repo.exists?(
      from run in Iri.Sync.SyncRun,
        where: run.provider_account_id == ^account_id and run.status in [:queued, :running]
    )
  end

  defp configured_client(key, default), do: Application.get_env(:iri, key) || default
end
