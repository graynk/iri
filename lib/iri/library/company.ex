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

defmodule Iri.Library.Company do
  @moduledoc "A publisher or developer record imported from catalog metadata."

  use Ecto.Schema
  import Ecto.Changeset

  schema "companies" do
    field :source, :string
    field :external_id, :string
    field :name, :string
    field :slug, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(company, attrs) do
    company
    |> cast(attrs, [:source, :external_id, :name, :slug])
    |> validate_required([:source, :external_id, :name, :slug])
    |> unique_constraint([:source, :external_id])
  end
end
