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

defmodule Iri do
  @moduledoc """
  Domain namespace for IRI's library, integration, synchronization, matching,
  media, collection, and account contexts.

  The public facades (`Iri.Library`, `Iri.Integrations`, `Iri.Sync`,
  `Iri.Collections`, `Iri.Matches`, and `Iri.AI`) own authorization and durable
  business workflows. Controllers and LiveViews should call those facades
  rather than query schemas directly.
  """
end
