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

defmodule IriWeb.PWATest do
  use IriWeb.ConnCase, async: true

  test "manifest launches the whole application in standalone mode with PNG icons" do
    manifest =
      :iri
      |> Application.app_dir("priv/static/manifest.webmanifest")
      |> File.read!()
      |> Jason.decode!()

    assert manifest["id"] == "/"
    assert manifest["start_url"] == "/library"
    assert manifest["scope"] == "/"
    assert manifest["display"] == "standalone"
    assert manifest["background_color"] == "#0f0e17"
    assert manifest["theme_color"] == "#0f0e17"

    assert [
             %{
               "src" => "/images/iri-icon-192.png",
               "sizes" => "192x192",
               "type" => "image/png"
             },
             %{
               "src" => "/images/iri-icon-512.png",
               "sizes" => "512x512",
               "type" => "image/png"
             }
           ] = manifest["icons"]

    for icon <- manifest["icons"] do
      path = Application.app_dir(:iri, "priv/static" <> icon["src"])
      assert File.regular?(path)
    end
  end

  test "root layout declares iOS standalone metadata and a PNG touch icon", %{conn: conn} do
    document =
      conn
      |> get(~p"/users/log-in")
      |> html_response(200)
      |> LazyHTML.from_fragment()

    assert document
           |> LazyHTML.filter(~s(meta[name="apple-mobile-web-app-capable"][content="yes"]))
           |> Enum.count() == 1

    assert document
           |> LazyHTML.filter(~s(meta[name="apple-mobile-web-app-title"][content="IRI"]))
           |> Enum.count() == 1

    assert document
           |> LazyHTML.filter(
             ~s(link[rel="apple-touch-icon"][sizes="180x180"][href="/images/iri-icon-180.png"])
           )
           |> Enum.count() == 1

    touch_icon = get(build_conn(), "/apple-touch-icon.png")
    assert get_resp_header(touch_icon, "content-type") == ["image/png"]
    assert byte_size(response(touch_icon, 200)) > 1_000
  end

  test "the application self-hosts Noto Sans", %{conn: conn} do
    stylesheet =
      __DIR__
      |> Path.join("../../assets/css/app.css")
      |> Path.expand()
      |> File.read!()

    assert stylesheet =~ ~s(--font-sans: "Noto Sans")

    for filename <- [
          "noto-sans-latin-400-900.woff2",
          "noto-sans-latin-ext-400-900.woff2"
        ] do
      assert stylesheet =~ "/fonts/#{filename}"

      font = get(conn, "/fonts/#{filename}")
      assert get_resp_header(font, "content-type") == ["font/woff2"]
      assert byte_size(response(font, 200)) > 30_000
    end
  end

  test "root layout applies a valid theme cookie before JavaScript loads", %{conn: conn} do
    html =
      conn
      |> put_req_cookie(IriWeb.Theme.cookie_name(), "light")
      |> get(~p"/users/log-in")
      |> html_response(200)

    document = LazyHTML.from_document(html)
    metadata = LazyHTML.from_fragment(html)

    assert document
           |> LazyHTML.filter(~s(html[data-theme="light"]))
           |> Enum.count() == 1

    assert ["#eff0f3"] =
             metadata
             |> LazyHTML.filter(~s(meta[name="theme-color"]))
             |> LazyHTML.attribute("content")

    assert metadata
           |> LazyHTML.filter("script:not([src])")
           |> Enum.empty?()
  end

  test "root layout rejects an unknown theme cookie", %{conn: conn} do
    html =
      conn
      |> put_req_cookie(IriWeb.Theme.cookie_name(), "not-a-theme")
      |> get(~p"/users/log-in")
      |> html_response(200)

    document = LazyHTML.from_document(html)
    metadata = LazyHTML.from_fragment(html)

    assert document
           |> LazyHTML.filter(~s(html[data-theme="dark"]))
           |> Enum.count() == 1

    assert ["#0f0e17"] =
             metadata
             |> LazyHTML.filter(~s(meta[name="theme-color"]))
             |> LazyHTML.attribute("content")
  end

  test "service worker does not cache the manifest that controls installation metadata" do
    source =
      :iri
      |> Application.app_dir("priv/static/service-worker.js")
      |> File.read!()

    refute source =~ ~s("/manifest.webmanifest")
  end
end
