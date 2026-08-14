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

defmodule Iri.ParamsTest do
  use ExUnit.Case, async: true

  alias Iri.Params

  describe "positive_integer/1" do
    test "accepts positive integers and complete integer strings" do
      assert Params.positive_integer(1) == 1
      assert Params.positive_integer(42) == 42
      assert Params.positive_integer("1") == 1
      assert Params.positive_integer("42") == 42
    end

    test "rejects non-positive and partially parsed values" do
      assert Params.positive_integer(0) == nil
      assert Params.positive_integer(-1) == nil
      assert Params.positive_integer("0") == nil
      assert Params.positive_integer("-1") == nil
      assert Params.positive_integer("12px") == nil
      assert Params.positive_integer("") == nil
    end

    test "rejects values outside its integer and string contract" do
      assert Params.positive_integer(nil) == nil
      assert Params.positive_integer(1.0) == nil
      assert Params.positive_integer(:one) == nil
      assert Params.positive_integer([]) == nil
    end
  end
end
