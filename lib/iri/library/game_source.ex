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

defmodule Iri.Library.GameSource do
  @moduledoc "A provider-specific game record, matched or unmatched, in the local catalog."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Library.{Game, LibraryItem, MatchCandidate}

  schema "game_sources" do
    field :provider, Ecto.Enum, values: [:steam, :gog, :igdb, :epic, :psn, :xbox]
    field :external_id, :string
    field :source_title, :string
    field :normalized_source_title, :string
    field :source_url, :string
    field :metadata_snapshot, :map, default: %{}
    field :match_method, :string
    field :manual_lock, :boolean, default: false
    field :catalog_kind, :string
    field :controller_support, :string
    field :deck_compatibility, :string
    field :protondb_tier, :string
    field :protondb_etag, :string
    field :protondb_checked_at, :utc_datetime
    field :available_windows, :boolean
    field :available_mac, :boolean
    field :available_linux, :boolean
    field :vr_support, :string
    field :nsfw, :boolean, default: false
    field :compatibility_checked_at, :utc_datetime

    belongs_to :game, Game
    has_many :library_items, LibraryItem
    has_many :match_candidates, MatchCandidate
    timestamps(type: :utc_datetime)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :provider,
      :external_id,
      :game_id,
      :source_title,
      :normalized_source_title,
      :source_url,
      :metadata_snapshot,
      :match_method,
      :manual_lock,
      :catalog_kind,
      :controller_support,
      :deck_compatibility,
      :protondb_tier,
      :protondb_etag,
      :protondb_checked_at,
      :available_windows,
      :available_mac,
      :available_linux,
      :vr_support,
      :nsfw,
      :compatibility_checked_at
    ])
    |> validate_required([:provider, :external_id, :source_title])
    |> unique_constraint([:provider, :external_id])
  end
end
