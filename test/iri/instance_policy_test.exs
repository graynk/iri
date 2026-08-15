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

defmodule Iri.InstancePolicyTest do
  use ExUnit.Case, async: false

  alias Iri.InstancePolicy

  setup do
    instance_mode = Application.get_env(:iri, :instance_mode)
    library_mode = Application.get_env(:iri, :mode)

    on_exit(fn ->
      Application.put_env(:iri, :instance_mode, instance_mode)
      Application.put_env(:iri, :mode, library_mode)
    end)
  end

  test "demo mode disables writes and registration independently of library sharing" do
    Application.put_env(:iri, :instance_mode, :demo)
    Application.put_env(:iri, :mode, :public)

    assert InstancePolicy.demo?()
    refute InstancePolicy.writable?()
    refute InstancePolicy.public_registration?()
    refute InstancePolicy.family?()
  end

  test "normal mode preserves existing Family and Public behavior" do
    Application.put_env(:iri, :instance_mode, :normal)
    Application.put_env(:iri, :mode, :public)

    refute InstancePolicy.demo?()
    assert InstancePolicy.writable?()
    assert InstancePolicy.public_registration?()
  end
end
