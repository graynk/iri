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

defmodule Iri.Library.UserGameState do
  @moduledoc "One user's private completion state, rating, and note for a canonical game."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Accounts.User
  alias Iri.Library.Game

  @ratings Enum.map(2..10, &(&1 / 2))

  schema "user_game_states" do
    field :state, :string
    field :notes, :string
    field :rating, :float
    belongs_to :user, User
    belongs_to :game, Game
    timestamps(type: :utc_datetime)
  end

  def changeset(state, attrs) do
    state
    |> cast(attrs, [:state, :notes, :rating])
    |> validate_inclusion(:state, ["backlog", "playing", "completed", "dropped"])
    |> validate_length(:notes, max: 10_000)
    |> validate_inclusion(:rating, @ratings)
    |> validate_number(:rating, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> unique_constraint(:game_id, name: :user_game_states_user_id_game_id_index)
    |> check_constraint(:rating, name: :user_game_states_rating_check)
  end

  def note_changeset(state, attrs) do
    state
    |> cast(attrs, [:notes])
    |> validate_length(:notes, max: 10_000)
  end
end
