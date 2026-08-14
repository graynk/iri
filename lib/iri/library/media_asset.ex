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

defmodule Iri.Library.MediaAsset do
  @moduledoc "Remote catalog media and optional local-cache state for a canonical game."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Library.Game

  schema "media_assets" do
    field :kind, :string
    field :source, :string
    field :remote_id, :string
    field :remote_url, :string
    field :position, :integer, default: 0
    field :local_path, :string
    field :content_hash, :string
    field :cache_status, :string, default: "remote"

    belongs_to :game, Game
    timestamps(type: :utc_datetime)
  end

  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :game_id,
      :kind,
      :source,
      :remote_id,
      :remote_url,
      :position,
      :local_path,
      :content_hash,
      :cache_status
    ])
    |> validate_required([:game_id, :kind, :source, :cache_status])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:game_id, :source, :kind, :remote_id],
      name: :media_assets_game_id_source_kind_remote_id_index
    )
  end
end
