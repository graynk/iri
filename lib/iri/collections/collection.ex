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

defmodule Iri.Collections.Collection do
  @moduledoc "A user-owned, explicitly ordered list of canonical games."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Accounts.User
  alias Iri.Collections.CollectionGame

  schema "collections" do
    field :name, :string
    field :sharing_enabled, :boolean, default: false
    field :share_version, :integer, default: 1

    belongs_to :user, User
    has_many :collection_games, CollectionGame
    timestamps(type: :utc_datetime)
  end

  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80)
    |> unique_constraint(:name, name: :collections_user_id_name_index)
  end

  def sharing_changeset(collection, attrs) do
    collection
    |> cast(attrs, [:sharing_enabled, :share_version])
    |> validate_required([:sharing_enabled, :share_version])
    |> validate_number(:share_version, greater_than: 0)
    |> check_constraint(:share_version, name: :collections_share_version_check)
  end
end
