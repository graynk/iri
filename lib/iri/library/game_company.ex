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

defmodule Iri.Library.GameCompany do
  @moduledoc "Associates a canonical game with a company and its catalog-provided role."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Library.{Company, Game}

  schema "game_companies" do
    field :role, :string
    belongs_to :game, Game
    belongs_to :company, Company
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(game_company, attrs) do
    game_company
    |> cast(attrs, [:game_id, :company_id, :role])
    |> validate_required([:game_id, :company_id, :role])
    |> unique_constraint([:game_id, :company_id, :role])
  end
end
