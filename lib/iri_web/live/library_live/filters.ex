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

defmodule IriWeb.LibraryLive.Filters do
  @moduledoc "URL and form-state helpers for the library browser's persisted filter controls."

  @defaults %{
    "q" => "",
    "tag_ids" => [],
    "providers" => [],
    "account_ids" => [],
    "genre_ids" => [],
    "theme_ids" => [],
    "game_modes" => [],
    "states" => [],
    "controllers" => [],
    "deck" => [],
    "platforms" => [],
    "sort" => "title",
    "direction" => "asc"
  }

  # Page slots rendered by the paginator, and how many leading/trailing pages are
  # listed before the current page gets its own window.
  @pagination_slots 7
  @edge_slots 4

  def defaults, do: @defaults

  def query(params, page \\ 1) do
    query =
      @defaults
      |> Map.keys()
      |> Enum.reduce(%{}, fn key, query ->
        case {key, Map.get(params, key)} do
          {"sort", "title"} ->
            query

          {"direction", "asc"} ->
            query

          {_key, value} when is_binary(value) ->
            value = String.trim(value)
            if value == "", do: query, else: Map.put(query, key, value)

          {_key, values} when is_list(values) ->
            values = values |> Enum.filter(&is_binary/1) |> Enum.reject(&(&1 == ""))
            if values == [], do: query, else: Map.put(query, key, values)

          _value ->
            query
        end
      end)

    if page > 1, do: Map.put(query, "page", page), else: query
  end

  @doc """
  Returns the page tokens to render, always `@pagination_slots` of them once the
  list is longer than that, so the control keeps the same width on every page.
  """
  def pagination_tokens(_page, page_count) when page_count <= @pagination_slots,
    do: Enum.to_list(1..page_count)

  def pagination_tokens(page, page_count) when page <= @edge_slots,
    do: Enum.to_list(1..(@edge_slots + 1)) ++ [:ellipsis, page_count]

  def pagination_tokens(page, page_count) when page > page_count - @edge_slots,
    do: [1, :ellipsis] ++ Enum.to_list((page_count - @edge_slots)..page_count)

  def pagination_tokens(page, page_count),
    do: [1, :ellipsis, page - 1, page, page + 1, :ellipsis, page_count]

  def merge_event(current, incoming, ["filters", target]) do
    current
    |> Map.merge(incoming)
    |> then(fn merged ->
      if Map.has_key?(incoming, target),
        do: merged,
        else: Map.put(merged, target, empty_value(target))
    end)
  end

  def merge_event(_current, incoming, _target), do: incoming

  def active?(filters) do
    Enum.any?(filters, fn
      {key, _value} when key in ["sort", "direction"] -> false
      {_key, value} when is_list(value) -> value != []
      {_key, value} -> value != ""
    end)
  end

  def active_count(filters) do
    Enum.reduce(filters, 0, fn
      {key, _value}, count when key in ["sort", "direction"] -> count
      {_key, value}, count when is_list(value) -> count + length(value)
      {_key, ""}, count -> count
      {_key, _value}, count -> count + 1
    end)
  end

  def account_options(accounts, current_user_id) do
    Enum.map(accounts, fn account ->
      {account_label(account, current_user_id), Integer.to_string(account.id)}
    end)
  end

  def term_options(terms), do: Enum.map(terms, &{&1.name, Integer.to_string(&1.id)})

  defp empty_value(key) when key in ["q", "sort", "direction"], do: ""
  defp empty_value(_key), do: []

  # Every user's custom library is internally named "Custom games", so label it
  # by its owner to keep shared libraries distinguishable in the filter.
  defp account_label(%{provider: :custom} = account, current_user_id) do
    if account.owner_user_id == current_user_id do
      "Custom · yours"
    else
      "Custom · #{account_owner_name(account)}"
    end
  end

  defp account_label(account, _current_user_id) do
    provider = account.provider |> Atom.to_string() |> String.upcase()
    "#{provider} · #{account.display_name || account.external_user_id}"
  end

  defp account_owner_name(%{owner_user: %{username: username}}) when is_binary(username),
    do: username

  defp account_owner_name(_account), do: "another user"
end
