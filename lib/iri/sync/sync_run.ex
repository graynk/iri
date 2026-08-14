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

defmodule Iri.Sync.SyncRun do
  @moduledoc "A durable import, enrichment, or compatibility-refresh execution record."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Integrations.ProviderAccount
  alias Iri.Sync.SyncError

  schema "sync_runs" do
    field :provider, Ecto.Enum, values: [:steam, :gog, :igdb, :custom, :epic, :psn, :xbox]
    field :stage, :string
    field :status, Ecto.Enum, values: [:queued, :running, :completed, :failed]
    field :checkpoint, :map, default: %{}
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :lease_expires_at, :utc_datetime
    field :discovered_count, :integer, default: 0
    field :inserted_count, :integer, default: 0
    field :updated_count, :integer, default: 0
    field :removed_count, :integer, default: 0
    field :matched_count, :integer, default: 0
    field :unmatched_count, :integer, default: 0
    field :failed_count, :integer, default: 0

    belongs_to :provider_account, ProviderAccount
    has_many :errors, SyncError
    timestamps(type: :utc_datetime)
  end

  def create_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :provider_account_id,
      :provider,
      :stage,
      :status,
      :checkpoint,
      :lease_expires_at
    ])
    |> validate_required([:stage, :status])
  end

  def progress_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :status,
      :checkpoint,
      :started_at,
      :finished_at,
      :lease_expires_at,
      :discovered_count,
      :inserted_count,
      :updated_count,
      :removed_count,
      :matched_count,
      :unmatched_count,
      :failed_count
    ])
    |> validate_required([:status])
  end
end
