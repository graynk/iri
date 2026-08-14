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

defmodule Iri.Integrations.ProviderRateLimit do
  @moduledoc "Durable shared request budget for an upstream provider."

  use Ecto.Schema
  import Ecto.Changeset

  schema "provider_rate_limits" do
    field :provider, :string
    field :window_ends_at, :utc_datetime
    field :requests_observed, :integer, default: 0
    field :blocked_until, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(limit, attrs) do
    limit
    |> cast(attrs, [
      :provider,
      :window_ends_at,
      :requests_observed,
      :blocked_until
    ])
    |> validate_required([:provider, :requests_observed])
    |> validate_number(:requests_observed, greater_than_or_equal_to: 0)
    |> unique_constraint(:provider)
  end
end
