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

defmodule Iri.AI.MatchReview do
  @moduledoc "Persistent AI matching job and recommendation for one unresolved game source."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Library.GameSource

  @statuses ~w(queued running retry_wait recommended abstained failed applied dismissed superseded)
  @actions ~w(match reject keep_store_only abstain)
  @catalogs ~w(igdb vndb store)

  schema "ai_match_reviews" do
    field :status, :string, default: "queued"
    field :action, :string
    field :selected_catalog, :string
    field :selected_external_id, :string
    field :selected_title, :string
    field :confidence, :float
    field :reason, :string
    field :model, :string
    field :prompt_version, :string, default: "1"
    field :source_fingerprint, :string
    field :failure_details, :map, default: %{}
    field :attempt_count, :integer, default: 0
    field :next_attempt_at, :utc_datetime
    field :lease_token, :string
    field :lease_expires_at, :utc_datetime
    field :last_error_category, :string
    field :last_error_message, :string

    belongs_to :game_source, GameSource
    timestamps(type: :utc_datetime)
  end

  def changeset(review, attrs) do
    review
    |> cast(attrs, [
      :status,
      :action,
      :selected_catalog,
      :selected_external_id,
      :selected_title,
      :confidence,
      :reason,
      :model,
      :prompt_version,
      :source_fingerprint,
      :failure_details,
      :attempt_count,
      :next_attempt_at,
      :lease_token,
      :lease_expires_at,
      :last_error_category,
      :last_error_message
    ])
    |> put_programmatic_id(:game_source_id, attrs)
    |> validate_required([
      :game_source_id,
      :status,
      :model,
      :prompt_version,
      :source_fingerprint
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:selected_catalog, @catalogs)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:game_source_id,
      name: :ai_match_reviews_active_fingerprint_index
    )
    |> foreign_key_constraint(:game_source_id)
  end

  defp put_programmatic_id(changeset, field, attrs) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> changeset
    end
  end
end
