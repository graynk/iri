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

defmodule Iri.Sync.ScheduledTask do
  @moduledoc "A durable periodic maintenance task coordinated through SQLite."

  use Ecto.Schema
  import Ecto.Changeset

  schema "scheduled_tasks" do
    field :name, :string
    field :kind, :string
    field :status, Ecto.Enum, values: [:idle, :running], default: :idle
    field :next_run_at, :utc_datetime
    field :lease_token, :string
    field :lease_expires_at, :utc_datetime
    field :consecutive_failures, :integer, default: 0
    field :last_finished_at, :utc_datetime
    field :last_error, :string
    field :rerun_requested, :boolean, default: false
    field :compatibility_requested, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :name,
      :kind,
      :status,
      :next_run_at,
      :lease_token,
      :lease_expires_at,
      :consecutive_failures,
      :last_finished_at,
      :last_error,
      :rerun_requested,
      :compatibility_requested
    ])
    |> validate_required([:name, :kind, :status, :next_run_at])
    |> validate_length(:name, max: 100)
    |> validate_length(:kind, max: 100)
    |> validate_length(:last_error, max: 1_000)
    |> unique_constraint(:name)
  end
end
