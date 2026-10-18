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

defmodule IriWeb.LibraryLive.FiltersTest do
  use ExUnit.Case, async: true

  alias IriWeb.LibraryLive.Filters

  test "sorting never counts as an applied filter" do
    descending_title = Map.put(Filters.defaults(), "direction", "desc")

    descending_rating =
      Map.merge(Filters.defaults(), %{"sort" => "rating", "direction" => "desc"})

    refute Filters.active?(descending_title)
    assert Filters.active_count(descending_title) == 0
    refute Filters.active?(descending_rating)
    assert Filters.active_count(descending_rating) == 0

    filtered = Map.put(descending_rating, "providers", ["steam"])
    assert Filters.active?(filtered)
    assert Filters.active_count(filtered) == 1
  end

  test "selecting recently added or release date starts with the newest games" do
    for sort <- ["date_added", "release_date"] do
      filters = Filters.merge_event(Filters.defaults(), %{"sort" => sort}, ["filters", "sort"])
      assert filters["sort"] == sort
      assert filters["direction"] == "desc"
    end
  end

  test "pagination keeps the same number of slots on every page" do
    assert Filters.pagination_tokens(1, 1) == [1]
    assert Filters.pagination_tokens(3, 7) == [1, 2, 3, 4, 5, 6, 7]

    for page_count <- [8, 12, 43] do
      for page <- 1..page_count do
        tokens = Filters.pagination_tokens(page, page_count)

        assert length(tokens) == 7,
               "page #{page} of #{page_count} rendered #{length(tokens)} slots: #{inspect(tokens)}"

        pages = Enum.filter(tokens, &is_integer/1)
        assert pages == Enum.sort(pages)
        assert pages == Enum.uniq(pages)
        assert List.first(pages) == 1
        assert List.last(pages) == page_count
        assert page in pages
      end
    end

    assert Filters.pagination_tokens(1, 43) == [1, 2, 3, 4, 5, :ellipsis, 43]
    assert Filters.pagination_tokens(3, 43) == [1, 2, 3, 4, 5, :ellipsis, 43]
    assert Filters.pagination_tokens(20, 43) == [1, :ellipsis, 19, 20, 21, :ellipsis, 43]
    assert Filters.pagination_tokens(43, 43) == [1, :ellipsis, 39, 40, 41, 42, 43]
  end

  test "URLs omit only the selected sort's default direction" do
    for sort <- ["title", "rating", "my_rating", "playtime", "release_date", "date_added"],
        direction <- ["asc", "desc"] do
      query = Filters.query(%{"sort" => sort, "direction" => direction})
      default = Iri.Library.default_direction(sort)
      assert Map.get(query, "direction", default) == direction
      assert Map.has_key?(query, "direction") == (direction != default)
    end
  end

  test "changing between sorts with the same default preserves direction" do
    for sorts <- [["title", "rating", "my_rating", "playtime"], ["date_added", "release_date"]],
        current_sort <- sorts,
        next_sort <- sorts,
        direction <- ["asc", "desc"] do
      current = Map.merge(Filters.defaults(), %{"sort" => current_sort, "direction" => direction})
      merged = Filters.merge_event(current, %{"sort" => next_sort}, ["filters", "sort"])
      assert merged["direction"] == direction
    end
  end

  test "changing between different defaults resets direction while other events preserve it" do
    current = Map.merge(Filters.defaults(), %{"sort" => "date_added", "direction" => "desc"})

    for sort <- ["title", "rating", "my_rating", "playtime"] do
      merged = Filters.merge_event(current, %{"sort" => sort}, ["filters", "sort"])
      assert merged["direction"] == "asc"
    end

    ascending = Map.put(current, "direction", "asc")

    assert Filters.merge_event(ascending, %{"q" => "portal"}, ["filters", "q"])["direction"] ==
             "asc"

    assert Filters.merge_event(ascending, %{"sort" => "date_added"}, ["filters", "sort"])[
             "direction"
           ] ==
             "asc"
  end
end
