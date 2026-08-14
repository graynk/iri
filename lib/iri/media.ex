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

defmodule Iri.Media do
  @moduledoc "Secure local caching and lookup for provider media."

  import Ecto.Query, warn: false

  alias Iri.Integrations.HTTP
  alias Iri.Library.MediaAsset
  alias Iri.Repo
  alias Iri.Security.Redactor

  @max_media_bytes 10 * 1024 * 1024
  @screenshot_batch_size 200
  @screenshot_concurrency 4
  @allowed_hosts ["images.igdb.com", "t.vndb.org"]

  @doc "Returns whether metadata refreshes should also cache remote screenshots locally."
  def download_screenshots? do
    Application.get_env(:iri, :download_screenshots, false)
  end

  @doc "Caches a canonical game's primary cover when it is remote or the local file is missing."
  def cache_cover(game_id, options \\ []) do
    asset =
      Repo.one(
        from asset in MediaAsset,
          where: asset.game_id == ^game_id and asset.kind == "cover",
          order_by: [asc: asset.position],
          limit: 1
      )

    case asset do
      %MediaAsset{cache_status: "ready"} = asset ->
        case get_cached_asset(asset.id) do
          {:ok, cached, _path} -> {:ok, cached}
          {:error, :not_found} -> cache_asset(asset, options)
        end

      %MediaAsset{} ->
        cache_asset(asset, options)

      nil ->
        {:ok, :no_cover}
    end
  end

  @doc "Returns a cached media asset and safe absolute path, never a path outside `media_root/0`."
  def get_cached_asset(id) do
    case Repo.get(MediaAsset, id) do
      %MediaAsset{cache_status: "ready", local_path: local_path} = asset
      when is_binary(local_path) ->
        root = media_root()
        path = Path.expand(local_path, root)

        if inside_root?(path, root) and File.regular?(path) do
          {:ok, asset, path}
        else
          {:error, :not_found}
        end

      _other ->
        {:error, :not_found}
    end
  end

  @doc """
  Caches every pending screenshot in bounded batches. Failed downloads remain
  eligible for a later metadata refresh, so an interrupted or partial run is
  safe to resume.
  """
  def cache_screenshots(options \\ []) do
    cache_screenshot_batches(0, options, %{cached: 0, failed: 0, failures: []})
  end

  @doc "Returns an allow-listed remote URL for uncached cover or screenshot media."
  def remote_fallback_url(%MediaAsset{kind: kind, remote_url: url})
      when kind in ["cover", "screenshot"] do
    case validate_url(url) do
      :ok -> {:ok, url}
      {:error, _reason} = error -> error
    end
  end

  def remote_fallback_url(_asset), do: {:error, :invalid_media_url}

  @doc """
  Repairs stale cache references, removes files no longer referenced by the
  database, and never deletes a file outside `media_root/0`.
  """
  def maintain_cache do
    root = media_root()
    assets = Repo.all(from asset in MediaAsset, where: asset.cache_status == "ready")

    {cached_assets, missing_assets_reset} =
      Enum.reduce(assets, {[], 0}, fn asset, {cached, missing_count} ->
        case cached_asset_path(asset, root) do
          {:ok, path} -> {[{asset, path} | cached], missing_count}
          :missing -> {cached, reset_missing_asset(asset) + missing_count}
        end
      end)

    cached_assets = Enum.reverse(cached_assets)
    cached_paths = cached_assets |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    orphaned_files_pruned =
      root
      |> media_files()
      |> Enum.reject(&MapSet.member?(cached_paths, &1))
      |> Enum.count(&(File.rm(&1) == :ok))

    {:ok,
     %{
       missing_assets_reset: missing_assets_reset,
       orphaned_files_pruned: orphaned_files_pruned
     }}
  end

  @doc "Returns the configured root directory for locally cached game media."
  def media_root do
    Application.get_env(:iri, :media_root, Path.expand("data/media"))
  end

  defp cache_screenshot_batches(after_id, options, counts) do
    ids = pending_screenshot_ids(after_id)

    case ids do
      [] ->
        {:ok, counts}

      _ids ->
        next_counts =
          ids
          |> Task.async_stream(
            fn id -> {id, cache_screenshot(id, options)} end,
            max_concurrency: @screenshot_concurrency,
            ordered: false,
            timeout: :infinity
          )
          |> Enum.reduce(counts, &count_screenshot_result/2)

        cache_screenshot_batches(List.last(ids), options, next_counts)
    end
  end

  defp pending_screenshot_ids(after_id) do
    Repo.all(
      from asset in MediaAsset,
        where:
          asset.id > ^after_id and asset.kind == "screenshot" and
            asset.cache_status in ["remote", "failed"] and not is_nil(asset.remote_url),
        order_by: [asc: asset.id],
        select: asset.id,
        limit: @screenshot_batch_size
    )
  end

  defp cache_screenshot(id, options) do
    case Repo.get(MediaAsset, id) do
      %MediaAsset{kind: "screenshot"} = asset -> cache_asset(asset, options)
      _asset -> {:error, :not_found}
    end
  end

  defp count_screenshot_result({:ok, {_id, {:ok, _asset}}}, counts) do
    %{counts | cached: counts.cached + 1}
  end

  defp count_screenshot_result({:ok, {id, {:error, reason}}}, counts) do
    %{
      counts
      | failed: counts.failed + 1,
        failures:
          Enum.take(
            counts.failures ++ [%{asset_id: id, reason: Redactor.redact_inspect(reason)}],
            20
          )
    }
  end

  defp count_screenshot_result({:exit, reason}, counts) do
    %{
      counts
      | failed: counts.failed + 1,
        failures:
          Enum.take(
            counts.failures ++ [%{asset_id: nil, reason: Redactor.redact_inspect(reason)}],
            20
          )
    }
  end

  defp cache_asset(%MediaAsset{} = asset, options) do
    with :ok <- validate_url(asset.remote_url),
         {:ok, response} <- request(asset, options),
         :ok <- validate_response(response),
         {:ok, relative_path, hash} <- write_asset(asset, response.body) do
      asset
      |> MediaAsset.changeset(%{
        local_path: relative_path,
        content_hash: hash,
        cache_status: "ready"
      })
      |> Repo.update()
    else
      {:error, _reason} = error ->
        asset
        |> MediaAsset.changeset(%{
          cache_status: "failed"
        })
        |> Repo.update()

        error
    end
  end

  defp request(asset, options) do
    request_fun = Keyword.get(options, :request, &HTTP.request/2)

    request_fun.(
      [method: :get, url: asset.remote_url, redirect: false, receive_timeout: 20_000],
      media_provider(asset.source)
    )
  end

  defp media_provider("vndb"), do: :vndb
  defp media_provider(_source), do: :igdb

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when host in @allowed_hosts -> :ok
      _uri -> {:error, :disallowed_media_url}
    end
  end

  defp validate_url(_url), do: {:error, :invalid_media_url}

  defp validate_response(%Req.Response{body: body} = response) when is_binary(body) do
    content_type = response |> Req.Response.get_header("content-type") |> List.first()

    cond do
      byte_size(body) > @max_media_bytes -> {:error, :media_too_large}
      not image_content_type?(content_type) -> {:error, :invalid_content_type}
      true -> :ok
    end
  end

  defp validate_response(_response), do: {:error, :invalid_media_response}

  defp image_content_type?(content_type) when is_binary(content_type) do
    media_type =
      content_type
      |> String.downcase()
      |> String.split(";", parts: 2)
      |> List.first()

    media_type in ["image/jpeg", "image/png", "image/webp"]
  end

  defp image_content_type?(_content_type), do: false

  defp write_asset(asset, body) do
    extension = image_extension(asset.remote_url)
    relative_path = Path.join(media_directory(asset), media_filename(asset, extension))
    final_path = Path.join(media_root(), relative_path)
    temporary_path = final_path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(final_path)),
         :ok <- File.write(temporary_path, body, [:binary]),
         :ok <- File.rename(temporary_path, final_path) do
      {:ok, relative_path, Base.encode16(:crypto.hash(:sha256, body), case: :lower)}
    else
      error ->
        File.rm(temporary_path)
        {:error, error}
    end
  end

  defp media_directory(%MediaAsset{kind: "screenshot"}), do: "screenshots"
  defp media_directory(_asset), do: "covers"

  defp media_filename(%MediaAsset{kind: "screenshot", id: id}, extension),
    do: "#{id}#{extension}"

  defp media_filename(asset, extension), do: "#{asset.remote_id || asset.id}#{extension}"

  defp image_extension(url) do
    case url |> URI.parse() |> Map.get(:path) |> Path.extname() |> String.downcase() do
      extension when extension in [".jpg", ".jpeg", ".png", ".webp"] -> extension
      _extension -> ".jpg"
    end
  end

  defp inside_root?(path, root) do
    expanded_root = Path.expand(root)
    path == expanded_root or String.starts_with?(path, expanded_root <> "/")
  end

  defp cached_asset_path(%MediaAsset{local_path: local_path}, root) when is_binary(local_path) do
    path = Path.expand(local_path, root)

    if inside_root?(path, root) and File.regular?(path), do: {:ok, path}, else: :missing
  end

  defp cached_asset_path(_asset, _root), do: :missing

  defp reset_missing_asset(asset) do
    case asset
         |> MediaAsset.changeset(%{
           cache_status: "remote",
           local_path: nil,
           content_hash: nil
         })
         |> Repo.update() do
      {:ok, _asset} -> 1
      {:error, _changeset} -> 0
    end
  end

  defp media_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.expand/1)
  end
end
