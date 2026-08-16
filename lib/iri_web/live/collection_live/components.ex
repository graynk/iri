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

defmodule IriWeb.CollectionLive.Components do
  @moduledoc "Shared presentational components for private and shared collection pages."

  use IriWeb, :html

  attr :variant, :atom, required: true, values: [:owner, :shared]
  attr :entries, :any, required: true
  attr :sort, :string, required: true
  attr :sort_direction, :string, required: true
  attr :next_cursor, :any, default: nil
  attr :owner_name, :string, default: nil
  attr :label, :string, default: "Collection games"

  def collection_listing(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/35">
      <div role="table" aria-label={@label}>
        <div role="rowgroup">
          <div
            role="row"
            class={[
              "grid grid-cols-[2.5rem_minmax(5.5rem,1fr)_2.5rem_3rem_2.75rem] items-center gap-2 border-b border-slate-800 bg-slate-900/80 px-3 py-3 text-[0.65rem] font-semibold tracking-wide text-slate-500 sm:gap-3 sm:px-4 sm:text-xs sm:tracking-wider",
              @variant == :owner && "sm:grid-cols-[3.25rem_minmax(0,1fr)_5rem_5rem_7rem]",
              @variant == :shared && "sm:grid-cols-[3.25rem_minmax(0,1fr)_5rem_5rem_8rem]"
            ]}
          >
            <span role="columnheader"><span class="sr-only">Cover</span></span>
            <span role="columnheader" aria-sort={aria_sort(@sort == "title", @sort_direction)}>
              <button
                id={sort_id(@variant, :title)}
                type="button"
                phx-click="sort_collection"
                phx-value-sort="title"
                class={sort_header(@sort == "title")}
              >
                Title <.sort_icon active={@sort == "title"} direction={@sort_direction} />
              </button>
            </span>
            <span
              role="columnheader"
              aria-sort={aria_sort(@sort == "release_year", @sort_direction)}
            >
              <button
                id={sort_id(@variant, :year)}
                type="button"
                phx-click="sort_collection"
                phx-value-sort="release_year"
                class={sort_header(@sort == "release_year")}
              >
                Year <.sort_icon active={@sort == "release_year"} direction={@sort_direction} />
              </button>
            </span>
            <span
              role="columnheader"
              aria-sort={aria_sort(@sort == "igdb_rating", @sort_direction)}
            >
              <button
                id={sort_id(@variant, :igdb)}
                type="button"
                phx-click="sort_collection"
                phx-value-sort="igdb_rating"
                class={sort_header(@sort == "igdb_rating")}
              >
                Rating <.sort_icon active={@sort == "igdb_rating"} direction={@sort_direction} />
              </button>
            </span>
            <span
              role="columnheader"
              class="min-w-0"
              aria-sort={aria_sort(@sort == "my_rating", @sort_direction)}
            >
              <button
                id={sort_id(@variant, :personal)}
                type="button"
                phx-click="sort_collection"
                phx-value-sort="my_rating"
                aria-label={rating_label(@variant, @owner_name)}
                title={rating_title(@variant, @owner_name)}
                class={sort_header(@sort == "my_rating")}
              >
                <span class={[
                  if(@variant == :owner,
                    do: "hidden whitespace-nowrap sm:inline",
                    else: "hidden min-w-0 overflow-hidden text-ellipsis whitespace-nowrap sm:block"
                  )
                ]}>
                  {rating_title(@variant, @owner_name)}
                </span>
                <.icon name="hero-face-smile" class="size-4 sm:hidden" />
                <.sort_icon active={@sort == "my_rating"} direction={@sort_direction} />
              </button>
            </span>
          </div>
        </div>

        <div
          id={entries_id(@variant)}
          phx-update="stream"
          role="rowgroup"
          class="divide-y divide-slate-800"
        >
          <div
            id={empty_id(@variant)}
            role="row"
            class="hidden px-6 py-16 text-center text-sm text-slate-500 only:block"
          >
            <span role="cell" aria-colspan="5">{empty_message(@variant)}</span>
          </div>
          <%= for {id, entry} <- @entries do %>
            <.owner_entry :if={@variant == :owner} id={id} entry={entry} />
            <.shared_entry :if={@variant == :shared} id={id} entry={entry} />
          <% end %>
        </div>
      </div>

      <button
        :if={@next_cursor}
        id={load_more_id(@variant)}
        type="button"
        phx-click="load_more"
        phx-disable-with="Loading…"
        class="flex min-h-12 w-full items-center justify-center border-t border-slate-800 px-4 py-3 text-sm font-semibold text-slate-300 transition hover:bg-slate-800/45 hover:text-heading"
      >
        Load more
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true

  defp owner_entry(assigns) do
    ~H"""
    <div
      id={@id}
      role="row"
      class="relative grid min-h-20 grid-cols-[2.5rem_minmax(5.5rem,1fr)_2.5rem_3rem_2.75rem] items-center gap-2 px-3 py-3 transition hover:bg-slate-800/45 sm:grid-cols-[3.25rem_minmax(0,1fr)_5rem_5rem_7rem] sm:gap-3 sm:px-4"
    >
      <.cover cover_id={@entry.cover_id} title={@entry.title} placeholder />
      <.entry_details entry={@entry} linked={true} stretched={true} />
      <.entry_values entry={@entry} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true

  defp shared_entry(assigns) do
    ~H"""
    <div
      id={@id}
      role="row"
      class="grid min-h-20 grid-cols-[2.5rem_minmax(5.5rem,1fr)_2.5rem_3rem_2.75rem] items-center gap-2 px-3 py-3 sm:grid-cols-[3.25rem_minmax(0,1fr)_5rem_5rem_8rem] sm:gap-3 sm:px-4"
    >
      <.cover cover_id={@entry.cover_id} title={@entry.title} />
      <.entry_details entry={@entry} linked={@entry.viewer_can_open} />
      <.entry_values entry={@entry} />
    </div>
    """
  end

  attr :cover_id, :integer, default: nil
  attr :title, :string, required: true
  attr :placeholder, :boolean, default: false

  defp cover(assigns) do
    ~H"""
    <div role="cell" class="aspect-[3/4] overflow-hidden rounded-md bg-slate-800">
      <img :if={@cover_id} src={~p"/media/#{@cover_id}"} alt="" class="size-full object-cover" />
      <span
        :if={!@cover_id && @placeholder}
        aria-hidden="true"
        class="grid size-full place-items-center font-bold text-slate-500"
      >
        {String.first(@title)}
      </span>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :linked, :boolean, required: true
  attr :stretched, :boolean, default: false

  defp entry_details(assigns) do
    ~H"""
    <div role="cell" class="min-w-0">
      <.link
        :if={@linked}
        navigate={~p"/games/#{@entry.slug}"}
        class={[
          "block break-words text-sm font-semibold text-slate-100 hover:text-teal-100",
          "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-300",
          @stretched && "static after:absolute after:inset-0"
        ]}
      >
        {@entry.title}
      </.link>
      <p :if={!@linked} class="break-words text-sm font-semibold text-slate-100">
        {@entry.title}
      </p>
      <p :if={@entry.comment} class="mt-1 text-xs leading-relaxed text-slate-400">
        {@entry.comment}
      </p>
    </div>
    """
  end

  attr :entry, :map, required: true

  defp entry_values(assigns) do
    ~H"""
    <span role="cell" class="text-xs text-slate-400 sm:text-sm">{year(@entry.release_year)}</span>
    <span role="cell" class="text-xs text-slate-300 sm:text-sm">{igdb(@entry.igdb_rating)}</span>
    <span role="cell">
      <span :if={@entry.personal_rating} class="sr-only">
        Rated {format_rating_value(@entry.personal_rating)} out of 5: {rating_label(
          @entry.personal_rating
        )}
      </span>
      <.rating_face
        :if={@entry.personal_rating}
        rating={@entry.personal_rating}
        class={["size-5 sm:size-6", rating_tone(@entry.personal_rating)]}
      />
      <span :if={!@entry.personal_rating} class="text-sm text-slate-600">
        <span class="sr-only">Not rated</span>
        <span aria-hidden="true">—</span>
      </span>
    </span>
    """
  end

  @doc false
  def next_sort(current_sort, _current_direction, clicked_sort)
      when current_sort != clicked_sort,
      do: {clicked_sort, "desc"}

  def next_sort(clicked_sort, "desc", clicked_sort), do: {clicked_sort, "asc"}
  def next_sort(_clicked_sort, "asc", _same_sort), do: {"custom", "asc"}
  def next_sort(_clicked_sort, _direction, same_sort), do: {same_sort, "desc"}

  @doc false
  def pluralize(1, singular, _plural), do: singular
  def pluralize(_count, _singular, plural), do: plural

  defp year(year) when is_integer(year), do: Integer.to_string(year)
  defp year(_year), do: "—"
  defp igdb(rating) when is_number(rating), do: "#{round(rating)}%"
  defp igdb(_rating), do: "—"

  defp sort_header(true),
    do: "inline-flex min-w-0 items-center gap-1 whitespace-nowrap text-left text-teal-100"

  defp sort_header(false),
    do:
      "inline-flex min-w-0 items-center gap-1 whitespace-nowrap text-left transition hover:text-slate-200"

  attr :active, :boolean, required: true
  attr :direction, :string, required: true

  defp sort_icon(assigns) do
    ~H"""
    <.icon
      :if={@active}
      name={if(@direction == "asc", do: "hero-chevron-up", else: "hero-chevron-down")}
      class="size-3 shrink-0"
    />
    """
  end

  defp aria_sort(false, _direction), do: nil
  defp aria_sort(true, "asc"), do: "ascending"
  defp aria_sort(true, _direction), do: "descending"

  defp sort_id(:owner, :title), do: "collection-sort-title"
  defp sort_id(:owner, :year), do: "collection-sort-year"
  defp sort_id(:owner, :igdb), do: "collection-sort-igdb"
  defp sort_id(:owner, :personal), do: "collection-sort-mine"
  defp sort_id(:shared, :title), do: "shared-collection-sort-title"
  defp sort_id(:shared, :year), do: "shared-collection-sort-year"
  defp sort_id(:shared, :igdb), do: "shared-collection-sort-igdb"
  defp sort_id(:shared, :personal), do: "shared-collection-sort-owner-rating"

  defp entries_id(:owner), do: "collection-games"
  defp entries_id(:shared), do: "shared-collection-games"
  defp empty_id(:owner), do: "collection-games-empty"
  defp empty_id(:shared), do: "shared-collection-games-empty"
  defp load_more_id(:owner), do: "load-more-collection-games"
  defp load_more_id(:shared), do: "load-more-shared-collection-games"
  defp empty_message(:owner), do: "This collection is empty. Use Edit to add games."
  defp empty_message(:shared), do: "No accessible games remain in this collection."
  defp rating_label(:owner, _owner_name), do: "Sort by my rating"
  defp rating_label(:shared, owner_name), do: "Sort by #{owner_name}'s rating"
  defp rating_title(:owner, _owner_name), do: "My rating"
  defp rating_title(:shared, owner_name), do: "#{owner_name}'s rating"
end
