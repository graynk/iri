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

defmodule Iri.Library.Game do
  @moduledoc "The canonical catalog record shared by one or more store sources."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Library.{GameCompany, GameSource, MediaAsset, TaxonomyTerm, UserGameState}

  schema "games" do
    field :igdb_id, :integer
    field :vndb_id, :string
    field :nsfw, :boolean, default: false
    field :title, :string
    field :normalized_title, :string
    field :slug, :string
    field :summary, :string
    field :release_date, :date
    field :release_year, :integer
    field :rating, :float
    field :time_to_beat_main_seconds, :integer
    field :time_to_beat_extra_seconds, :integer
    field :nsfw_override, :boolean

    has_many :sources, GameSource
    has_many :media_assets, MediaAsset
    has_many :game_companies, GameCompany
    has_many :user_states, UserGameState
    many_to_many :terms, TaxonomyTerm, join_through: "game_terms"
    timestamps(type: :utc_datetime)
  end

  def changeset(game, attrs) do
    game
    |> cast(attrs, [
      :igdb_id,
      :vndb_id,
      :nsfw,
      :title,
      :normalized_title,
      :slug,
      :summary,
      :release_date,
      :release_year,
      :rating,
      :time_to_beat_main_seconds,
      :time_to_beat_extra_seconds,
      :nsfw_override
    ])
    |> validate_required([:title, :normalized_title, :slug])
    |> validate_number(:time_to_beat_main_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:time_to_beat_extra_seconds, greater_than_or_equal_to: 0)
    |> unique_constraint(:igdb_id)
    |> unique_constraint(:vndb_id)
    |> unique_constraint(:slug)
  end
end
