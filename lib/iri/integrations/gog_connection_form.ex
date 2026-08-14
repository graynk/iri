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

defmodule Iri.Integrations.GOGConnectionForm do
  @moduledoc "Validation-only form for a public GOG profile identifier."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :profile, :string
  end

  def changeset(form, attrs) do
    form
    |> cast(attrs, [:profile])
    |> update_change(:profile, &String.trim/1)
    |> validate_required([:profile])
    |> validate_length(:profile, max: 500)
  end
end
