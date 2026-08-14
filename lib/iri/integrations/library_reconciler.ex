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

defmodule Iri.Integrations.LibraryReconciler do
  @moduledoc """
  Reconciles normalized provider entries with IRI's shared library records.

  Incoming entries create or update provider game sources and the account's
  library items. When the incoming list is complete, library items absent from
  it are marked as removed; partial lists leave absent items unchanged.
  """

  import Ecto.Query, warn: false

  alias Iri.Accounts.{Scope, User}
  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{GameSource, LibraryItem, Title}
  alias Iri.Repo
  alias Iri.Security.Redactor
  alias Iri.Sync.{SyncError, SyncRun}

  @providers [:epic, :psn, :xbox]

  @doc "Creates or reuses a provider account and imports normalized library entries."
  def import(scope, provider, account_attrs, entries, options \\ [])

  def import(%Scope{user: %User{} = user}, provider, account_attrs, entries, options)
      when provider in @providers and is_list(entries) do
    complete? = Keyword.get(options, :complete, false)

    with {:ok, account} <-
           Repo.transact_with_busy_retry(
             fn -> get_or_create_account(user, provider, account_attrs) end,
             mode: :immediate
           ),
         {:ok, run} <- create_run(account),
         {:ok, counts} <- execute_run(run, account, entries, complete?) do
      {:ok, %{account: account, counts: counts, sync_run: run}}
    end
  end

  def import(_scope, _provider, _attrs, _entries, _options), do: {:error, :unauthorized}

  @doc "Reconciles normalized entries with shared sources and account-specific library items."
  def reconcile(%ProviderAccount{} = account, entries, complete?) do
    now = DateTime.utc_now(:second)
    entries = Enum.uniq_by(entries, & &1.external_id)
    external_ids = Enum.map(entries, & &1.external_id)
    existing = source_map(account.provider, external_ids)

    rows = Enum.map(entries, &source_row(account.provider, &1, now))

    Repo.insert_all(GameSource, rows,
      conflict_target: [:provider, :external_id],
      on_conflict:
        {:replace,
         [
           :source_title,
           :normalized_source_title,
           :source_url,
           :metadata_snapshot,
           :catalog_kind,
           :updated_at
         ]}
    )

    sources = source_map(account.provider, external_ids)
    relationships = existing_relationships(account.id, Map.values(sources))

    item_rows =
      Enum.map(entries, fn entry ->
        %{
          provider_account_id: account.id,
          game_source_id: Map.fetch!(sources, entry.external_id),
          relationship:
            strongest_relationship(
              relationships[Map.fetch!(sources, entry.external_id)],
              Map.get(entry, :relationship, :owned)
            ),
          hidden: false,
          playtime_minutes: Map.get(entry, :playtime_minutes) || 0,
          removed_at: nil,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(LibraryItem, item_rows,
      conflict_target: [:provider_account_id, :game_source_id],
      on_conflict:
        {:replace,
         [
           :relationship,
           :hidden,
           :playtime_minutes,
           :removed_at,
           :updated_at
         ]}
    )

    removed = if complete?, do: remove_absent(account, Map.values(sources), now), else: 0

    {:ok,
     %{
       discovered_count: length(entries),
       inserted_count: Enum.count(external_ids, &(not Map.has_key?(existing, &1))),
       updated_count: Enum.count(external_ids, &Map.has_key?(existing, &1)),
       removed_count: removed
     }}
  end

  @doc """
  Retires this account's items whose stored source matches the predicate.

  Partial-history reconciliation cannot retire absent entries, so entries a
  provider filter would no longer import (demos, apps) must be retired by
  inspecting their stored provider metadata instead.
  """
  def retire_matching(%ProviderAccount{} = account, predicate) when is_function(predicate, 1) do
    now = DateTime.utc_now(:second)

    item_ids =
      Repo.all(
        from item in LibraryItem,
          join: source in assoc(item, :game_source),
          where: item.provider_account_id == ^account.id and is_nil(item.removed_at),
          select: {item.id, source.source_title, source.metadata_snapshot}
      )
      |> Enum.filter(fn {_id, title, snapshot} ->
        predicate.(%{source_title: title, metadata_snapshot: snapshot})
      end)
      |> Enum.map(&elem(&1, 0))

    {count, _} =
      Repo.update_all(
        from(item in LibraryItem, where: item.id in ^item_ids),
        set: [removed_at: now, updated_at: now]
      )

    count
  end

  defp create_run(account) do
    now = DateTime.utc_now(:second)

    %SyncRun{}
    |> SyncRun.create_changeset(%{
      provider_account_id: account.id,
      provider: account.provider,
      stage: "#{account.provider}_library_import",
      status: :queued,
      checkpoint: %{"step" => "queued"},
      lease_expires_at: DateTime.add(now, 10_800, :second)
    })
    |> Repo.insert()
  end

  defp execute_run(run, account, entries, complete?) do
    now = DateTime.utc_now(:second)

    run =
      run
      |> SyncRun.progress_changeset(%{
        status: :running,
        started_at: now,
        checkpoint: %{"step" => "reconciling"}
      })
      |> Repo.update!()

    case Repo.transact_with_busy_retry(fn -> reconcile(account, entries, complete?) end,
           mode: :immediate
         ) do
      {:ok, counts} ->
        run
        |> SyncRun.progress_changeset(
          Map.merge(counts, %{
            status: :completed,
            finished_at: DateTime.utc_now(:second),
            checkpoint: %{"step" => "complete"}
          })
        )
        |> Repo.update!()

        account
        |> ProviderAccount.sync_status_changeset(%{
          sync_status: "ready"
        })
        |> Repo.update!()

        {:ok, counts}

      {:error, reason} ->
        fail_run(run, reason)
        {:error, reason}
    end
  rescue
    exception ->
      fail_run(run, exception)
      {:error, exception}
  end

  defp fail_run(run, reason) do
    message = reason |> Redactor.redact_inspect() |> String.slice(0, 500)

    Repo.transact(fn ->
      %SyncError{}
      |> SyncError.changeset(%{
        sync_run_id: run.id,
        stage: run.stage,
        kind: "library_import",
        message: message,
        retryable: true
      })
      |> Repo.insert!()

      run
      |> SyncRun.progress_changeset(%{
        status: :failed,
        finished_at: DateTime.utc_now(:second),
        failed_count: 1,
        checkpoint: %{"step" => "failed"}
      })
      |> Repo.update!()

      if run.provider_account_id do
        run.provider_account_id
        |> Repo.get(ProviderAccount)
        |> case do
          %ProviderAccount{} = account ->
            account
            |> ProviderAccount.sync_status_changeset(%{
              sync_status: "error"
            })
            |> Repo.update!()

          nil ->
            :ok
        end
      end

      {:ok, :failed}
    end)
  end

  defp get_or_create_account(user, provider, attrs) do
    external_id = Map.fetch!(attrs, :external_user_id)

    account =
      Repo.get_by(ProviderAccount, provider: provider, external_user_id: external_id) ||
        %ProviderAccount{}

    if account.owner_user_id not in [nil, user.id], do: Repo.rollback(:account_already_connected)

    account
    |> ProviderAccount.changeset(%{
      provider: provider,
      external_user_id: external_id,
      display_name: Map.get(attrs, :display_name, external_id),
      enabled: true
    })
    |> Ecto.Changeset.put_change(:owner_user_id, user.id)
    |> Ecto.Changeset.put_change(:sync_status, "completed")
    |> Repo.insert_or_update()
  end

  defp source_map(_provider, []), do: %{}

  defp source_map(provider, external_ids) do
    Repo.all(
      from source in GameSource,
        where: source.provider == ^provider and source.external_id in ^external_ids,
        select: {source.external_id, source.id}
    )
    |> Map.new()
  end

  defp existing_relationships(_account_id, []), do: %{}

  defp existing_relationships(account_id, source_ids) do
    Repo.all(
      from item in LibraryItem,
        where: item.provider_account_id == ^account_id and item.game_source_id in ^source_ids,
        select: {item.game_source_id, item.relationship}
    )
    |> Map.new()
  end

  defp strongest_relationship(:owned, _new), do: :owned
  defp strongest_relationship(_existing, :owned), do: :owned
  defp strongest_relationship(_existing, relationship), do: relationship

  defp source_row(provider, entry, now) do
    snapshot = Map.get(entry, :metadata, %{})

    %{
      provider: provider,
      external_id: entry.external_id,
      source_title: entry.title,
      normalized_source_title: Title.normalize(entry.title),
      source_url: Map.get(entry, :source_url),
      metadata_snapshot: snapshot,
      catalog_kind: "game",
      manual_lock: false,
      inserted_at: now,
      updated_at: now
    }
  end

  defp remove_absent(account, source_ids, now) do
    query =
      from item in LibraryItem,
        join: source in assoc(item, :game_source),
        where:
          item.provider_account_id == ^account.id and source.provider == ^account.provider and
            is_nil(item.removed_at)

    query =
      if source_ids == [],
        do: query,
        else: from([item, source] in query, where: item.game_source_id not in ^source_ids)

    {count, _} = Repo.update_all(query, set: [removed_at: now, updated_at: now])
    count
  end
end
