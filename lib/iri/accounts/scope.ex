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

defmodule Iri.Accounts.Scope do
  @moduledoc """
  Authorization context passed to IRI's context APIs.

  A user scope contains the authenticated user and that user's `:admin` or
  `:viewer` role. Context functions use it to scope data to the user and to
  guard administrator-only actions. Scheduled system work uses an explicit
  scope with the administrator role and no user.
  """

  alias Iri.Accounts.User

  defstruct user: nil, role: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user, role: user.role}
  end

  def for_user(nil), do: nil

  def admin?(%__MODULE__{role: :admin}), do: true
  def admin?(_scope), do: false
end
