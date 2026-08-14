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

defmodule Iri.Library.TitleTest do
  use ExUnit.Case, async: true

  alias Iri.Library.Title

  test "cleans ownership marks without discarding meaningful title punctuation" do
    assert Title.for_provider_search("  Call of Duty®: Test™  ") == "Call of Duty: Test"

    assert Title.for_provider_search("Fixture (R) [TM] {sm} (c) — Complete") ==
             "Fixture — Complete"
  end

  test "removes invisible storefront formatting" do
    assert Title.for_provider_search("Portal\u200B Reloaded\u00AD") == "Portal Reloaded"
  end

  test "leaves the stable title normalizer independent" do
    assert Title.normalize("Fixture™ (R)") == "fixture r"
  end
end
