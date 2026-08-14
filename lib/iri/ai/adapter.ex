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

defmodule Iri.AI.Adapter do
  @moduledoc "Behaviour implemented by AI-provider adapters used for catalog-match decisions."

  alias Iri.AI.{Config, MatchDecision, MatchRequest, ProviderError}

  @callback validate_configuration(Config.t()) :: :ok | {:error, ProviderError.t()}
  @callback decide(MatchRequest.t(), Config.t(), keyword()) ::
              {:ok, MatchDecision.t()} | {:error, ProviderError.t()}
end
