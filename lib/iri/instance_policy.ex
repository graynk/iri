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

defmodule Iri.InstancePolicy do
  @moduledoc "Runtime policy for account registration and inherited library sharing."

  @type mode :: :family | :public

  @doc "Returns the instance's configured Family or Public mode."
  def mode, do: Application.get_env(:iri, :mode, :family)

  @doc "Returns whether libraries inherit Family-mode sharing by default."
  def family?, do: mode() == :family

  @doc "Returns whether public account registration is enabled."
  def public_registration?, do: mode() == :public

  @doc "Returns whether a new provider account inherits instance-wide sharing."
  def account_shared_by_default?, do: family?()

  @doc "Returns the configured mode's display label."
  def label do
    if family?(), do: "Family mode", else: "Public mode"
  end
end
