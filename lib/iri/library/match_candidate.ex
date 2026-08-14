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

defmodule Iri.Library.MatchCandidate do
  @moduledoc "A persisted deterministic IGDB candidate for an unresolved store source."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Library.GameSource

  schema "match_candidates" do
    field :igdb_id, :integer
    field :title, :string
    field :score, :float, default: 0.0
    field :metadata, :map, default: %{}
    belongs_to :game_source, GameSource
    timestamps(type: :utc_datetime)
  end

  def changeset(candidate, attrs) do
    candidate
    |> cast(attrs, [:game_source_id, :igdb_id, :title, :score, :metadata])
    |> validate_required([:game_source_id, :igdb_id, :title, :score])
    |> unique_constraint([:game_source_id, :igdb_id])
  end
end
