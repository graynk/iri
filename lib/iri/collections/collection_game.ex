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

defmodule Iri.Collections.CollectionGame do
  @moduledoc "Join record that stores a game's position and private comment within a collection."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Collections.Collection
  alias Iri.Library.Game

  schema "collection_games" do
    field :position, :integer
    field :comment, :string
    belongs_to :collection, Collection
    belongs_to :game, Game
    timestamps(type: :utc_datetime)
  end

  def changeset(collection_game, attrs) do
    collection_game
    |> cast(attrs, [:position, :comment])
    |> update_change(:comment, &normalize_comment/1)
    |> validate_required([:position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_length(:comment, max: 300)
    |> unique_constraint([:collection_id, :game_id],
      name: :collection_games_collection_id_game_id_index
    )
  end

  def comment_changeset(collection_game, attrs) do
    collection_game
    |> cast(attrs, [:comment])
    |> update_change(:comment, &normalize_comment/1)
    |> validate_length(:comment, max: 300)
  end

  defp normalize_comment(nil), do: nil

  defp normalize_comment(comment) do
    case String.trim(comment) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
