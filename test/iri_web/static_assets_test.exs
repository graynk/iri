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

defmodule IriWeb.StaticAssetsTest do
  use IriWeb.ConnCase, async: true

  test "serves install metadata and the credential-free PSN helper", %{conn: conn} do
    manifest = get(conn, "/manifest.webmanifest")
    manifest_body = response(manifest, 200)
    assert manifest_body =~ ~s("display": "standalone")
    assert manifest_body =~ ~s("id": "/")
    assert manifest_body =~ ~s("start_url": "/library")
    assert manifest_body =~ ~s("scope": "/")

    helper = get(build_conn(), "/helpers/psn-collector.js")
    body = response(helper, 200)

    assert body =~ "window.IriPSN"
    assert body =~ ~s|captureLibrarySnapshot("/recently-played")|
    assert body =~ ~s|captureLibrarySnapshot("/recently-purchased")|
    assert body =~ "body?.props?.apolloState?.ROOT_QUERY"
    refute body =~ " · "
    refute body =~ "NPSSO"
  end

  test "serves digested root-level install metadata" do
    static_root =
      Path.join(
        System.tmp_dir!(),
        "iri-digested-static-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(static_root)
    File.write!(Path.join(static_root, "manifest-deadbeef.webmanifest"), ~s({"name":"IRI"}))
    on_exit(fn -> File.rm_rf!(static_root) end)

    options =
      Plug.Static.init(
        at: "/",
        from: static_root,
        only: IriWeb.static_paths(),
        only_matching: IriWeb.static_path_prefixes()
      )

    conn =
      :get
      |> Plug.Test.conn("/manifest-deadbeef.webmanifest")
      |> Plug.Static.call(options)

    assert conn.halted
    assert response(conn, 200) == ~s({"name":"IRI"})
  end
end
