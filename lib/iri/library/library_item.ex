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

defmodule Iri.Library.LibraryItem do
  @moduledoc "A provider account's relationship, playtime, and visibility for one store source."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.GameSource

  schema "library_items" do
    field :relationship, Ecto.Enum,
      values: [:owned, :subscription, :played, :manual],
      default: :owned

    field :hidden, :boolean, default: false
    field :manually_added, :boolean, default: false
    field :playtime_minutes, :integer, default: 0
    field :removed_at, :utc_datetime

    belongs_to :provider_account, ProviderAccount
    belongs_to :game_source, GameSource
    timestamps(type: :utc_datetime)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :provider_account_id,
      :game_source_id,
      :relationship,
      :hidden,
      :manually_added,
      :playtime_minutes,
      :removed_at
    ])
    |> validate_required([:provider_account_id, :game_source_id])
    |> validate_number(:playtime_minutes, greater_than_or_equal_to: 0)
    |> unique_constraint([:provider_account_id, :game_source_id])
  end
end
