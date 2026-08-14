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

defmodule Iri.Matches.MatchDecision do
  @moduledoc "Immutable audit record for a manual or AI-assisted source matching decision."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Accounts.User
  alias Iri.AI.MatchReview
  alias Iri.Library.GameSource

  @actors ~w(system ai admin)
  @actions ~w(match reject keep_store_only reopen)
  @catalogs ~w(igdb vndb store)

  schema "match_decisions" do
    field :actor_type, :string
    field :action, :string
    field :selected_catalog, :string
    field :selected_external_id, :string
    field :reason, :string
    field :confidence, :float

    belongs_to :game_source, GameSource
    belongs_to :ai_match_review, MatchReview
    belongs_to :admin_user, User
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :actor_type,
      :action,
      :selected_catalog,
      :selected_external_id,
      :reason,
      :confidence
    ])
    |> put_programmatic_id(:game_source_id, attrs)
    |> put_programmatic_id(:ai_match_review_id, attrs)
    |> put_programmatic_id(:admin_user_id, attrs)
    |> validate_required([
      :game_source_id,
      :actor_type,
      :action
    ])
    |> validate_inclusion(:actor_type, @actors)
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:selected_catalog, @catalogs)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:game_source_id)
    |> foreign_key_constraint(:ai_match_review_id)
    |> foreign_key_constraint(:admin_user_id)
  end

  defp put_programmatic_id(changeset, field, attrs) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> changeset
    end
  end
end
