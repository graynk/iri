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

defmodule IriWeb.MediaController do
  @moduledoc "Serves locally cached game media or safely redirects to its provider fallback URL."

  use IriWeb, :controller

  alias Iri.Media
  alias Iri.Media.Policy
  alias Iri.Library.MediaAsset
  alias Iri.Repo

  def show(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         %MediaAsset{} = asset <- Repo.get(MediaAsset, id) do
      asset = Repo.preload(asset, game: [:terms, :sources])

      if Policy.hidden?(asset.game, conn.assigns.current_scope) do
        send_resp(conn, 404, "Not found")
      else
        serve(conn, asset)
      end
    else
      _error -> send_resp(conn, 404, "Not found")
    end
  end

  defp serve(conn, asset) do
    case Media.get_cached_asset(asset.id) do
      {:ok, cached_asset, path} ->
        conn
        |> put_resp_content_type(content_type(path))
        |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
        |> put_resp_header("etag", cached_asset.content_hash || "#{cached_asset.id}")
        |> send_file(200, path)

      {:error, :not_found} ->
        case Media.remote_fallback_url(asset) do
          {:ok, url} ->
            conn
            |> put_resp_header("cache-control", "private, no-store")
            |> redirect(external: url)

          {:error, _reason} ->
            send_resp(conn, 404, "Not found")
        end
    end
  end

  defp content_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _extension -> "image/jpeg"
    end
  end
end
