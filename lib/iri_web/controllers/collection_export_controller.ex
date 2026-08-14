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

defmodule IriWeb.CollectionExportController do
  @moduledoc "Authenticated CSV, text, and static-website collection downloads."

  use IriWeb, :controller

  alias Iri.Collections
  alias Iri.Collections.Export
  alias Iri.Collections.StaticExport
  alias Iri.Library.Title

  def csv(conn, %{"id" => id}), do: export(conn, id, :csv)
  def txt(conn, %{"id" => id}), do: export(conn, id, :txt)

  def static(conn, %{"id" => id}) do
    with {:ok, export} <-
           Collections.export_static_collection(conn.assigns.current_scope, id),
         {:ok, archive} <- StaticExport.build(export, conn.assigns.theme) do
      filename = filename(export.collection.name, export.collection.id, "zip")

      conn
      |> put_resp_content_type("application/zip")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> put_resp_header("cache-control", "private, no-store")
      |> send_resp(:ok, archive)
    else
      {:error, :not_found} -> send_resp(conn, :not_found, "Collection not found.\n")
      {:error, :unauthorized} -> send_resp(conn, :not_found, "Collection not found.\n")
      {:error, _reason} -> send_resp(conn, :internal_server_error, "Could not build export.\n")
    end
  end

  defp export(conn, collection_id, format) do
    case Collections.export_collection(conn.assigns.current_scope, collection_id) do
      {:ok, collection, entries} ->
        {content_type, extension, body} = format(format, collection, entries)
        filename = filename(collection.name, collection.id, extension)

        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> put_resp_header("cache-control", "private, no-store")
        |> send_resp(:ok, body)

      {:error, _reason} ->
        send_resp(conn, :not_found, "Collection not found.\n")
    end
  end

  defp format(:csv, _collection, entries),
    do: {"text/csv", "csv", Export.csv(entries)}

  defp format(:txt, collection, entries),
    do: {"text/plain", "txt", Export.text(collection, entries)}

  defp filename(name, id, extension) do
    base =
      case Title.slug(name) do
        "" -> "collection-#{id}"
        slug -> slug
      end

    "#{base}.#{extension}"
  end
end
