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

defmodule Iri.Integrations.ProviderAccountShare do
  @moduledoc "An explicit user grant or follower link for a provider account."

  use Ecto.Schema

  alias Iri.Accounts.User
  alias Iri.Integrations.ProviderAccount

  @primary_key false
  schema "provider_account_shares" do
    field :linked, :boolean, default: false
    belongs_to :provider_account, ProviderAccount, primary_key: true
    belongs_to :user, User, primary_key: true
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
