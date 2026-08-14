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

defmodule Iri.Integrations.ProviderAccount do
  @moduledoc "A connected external library identity and its synchronization configuration."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Accounts.User
  alias Iri.Integrations.ProviderAccountShare

  @type t :: %__MODULE__{}

  schema "provider_accounts" do
    field :provider, Ecto.Enum, values: [:steam, :gog, :custom, :epic, :psn, :xbox]
    field :external_user_id, :string
    field :display_name, :string
    field :enabled, :boolean, default: true

    field :sharing_policy, Ecto.Enum,
      values: [:inherit, :everyone, :selected_users],
      default: :inherit

    field :sync_status, :string, default: "never_synced"

    belongs_to :owner_user, User
    has_many :shares, ProviderAccountShare
    many_to_many :shared_users, User, join_through: ProviderAccountShare
    timestamps(type: :utc_datetime)
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :provider,
      :external_user_id,
      :display_name,
      :enabled,
      :sharing_policy
    ])
    |> update_change(:external_user_id, &String.trim/1)
    |> update_change(:display_name, &String.trim/1)
    |> validate_required([:provider, :external_user_id])
    |> validate_length(:external_user_id, max: 255)
    |> validate_length(:display_name, max: 255)
    |> unique_constraint([:provider, :external_user_id])
  end

  def sync_status_changeset(account, attrs) do
    cast(account, attrs, [:sync_status])
  end
end
