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

defmodule Iri.Security.SafeTextTest do
  use ExUnit.Case, async: true

  alias Iri.Security.SafeText

  test "keeps a useful UTF-8 prefix and omits trailing binary data" do
    assert SafeText.display(<<"HTTP 429: ", 31, 139, 8>>) ==
             "HTTP 429: [non-text data omitted]"
  end

  test "normalizes control characters in otherwise valid text" do
    assert SafeText.display(<<"provider", 0, "failure">>) == "provider failure"
  end
end
