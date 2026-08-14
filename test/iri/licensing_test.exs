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

defmodule Iri.LicensingTest do
  use ExUnit.Case, async: true

  @notice "This file is part of IRI."

  @source_globs [
    ".formatter.exs",
    "mix.exs",
    "assets/css/**/*.css",
    "assets/js/**/*.js",
    "config/**/*.exs",
    "lib/**/*.ex",
    "lib/**/*.heex",
    "priv/repo/**/*.exs",
    "priv/repo/migrations/.formatter.exs",
    "priv/static/helpers/**/*.js",
    "priv/static/service-worker.js",
    "test/**/*.ex",
    "test/**/*.exs",
    "test/**/*.mjs"
  ]

  test "source files carry the copyright and license notice" do
    source_files =
      @source_globs
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.sort()

    missing_notices =
      Enum.reject(source_files, fn path ->
        path
        |> File.read!()
        |> String.contains?(@notice)
      end)

    assert source_files != []
    assert missing_notices == []
  end
end
