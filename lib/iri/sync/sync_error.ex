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

defmodule Iri.Sync.SyncError do
  @moduledoc "A redacted diagnostic captured during a durable synchronization run."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Security.SafeText
  alias Iri.Sync.SyncRun

  schema "sync_errors" do
    field :stage, :string
    field :kind, :string
    field :message, :string
    field :retryable, :boolean, default: false
    belongs_to :sync_run, SyncRun
    timestamps(type: :utc_datetime)
  end

  def changeset(error, attrs) do
    error
    |> cast(attrs, [
      :sync_run_id,
      :stage,
      :kind,
      :message,
      :retryable
    ])
    |> update_change(:message, &SafeText.display/1)
    |> validate_required([:sync_run_id, :stage, :kind, :message])
    |> validate_length(:message, max: 1_000)
  end
end
