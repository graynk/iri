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

defmodule IriWeb.StatusManagerLive.Presentation do
  @moduledoc "Presentation helpers for the compact status-management interface."

  import IriWeb.CoreComponents,
    only: [format_rating_value: 1, half_rating?: 1, rating_face_index: 1, rating_swatch: 1]

  def cover_asset(game), do: List.first(game.media_assets)

  def personal_state(%{user_states: [%{state: state} | _rest]})
      when state in ["backlog", "playing", "completed", "dropped"],
      do: state

  def personal_state(_game), do: "not_played"

  def personal_rating(%{user_states: [%{rating: rating} | _rest]})
      when is_number(rating) and rating >= 1 and rating <= 5,
      do: rating

  def personal_rating(_game), do: nil

  def rating_action_label(game, rating) do
    action = if personal_rating(game) == rating, do: "Clear", else: "Set"
    "#{action} personal rating: #{format_rating_value(rating)} out of 5"
  end

  def selected_rating_face?(game, face) do
    case personal_rating(game) do
      rating when is_number(rating) -> rating_face_index(rating) == face
      _rating -> false
    end
  end

  def rating_face_value(game, face) do
    if selected_rating_face?(game, face), do: personal_rating(game), else: face
  end

  def half_toggle_value(game) do
    rating = personal_rating(game)
    if half_rating?(rating), do: ceil(rating) / 1, else: rating - 0.5
  end

  def half_toggle_label(game) do
    value = half_toggle_value(game)
    "Set personal rating: #{format_rating_value(value)} out of 5"
  end

  def status_rating_class(selected?, rating) do
    selected_class = rating_swatch(rating)

    [
      "grid size-7 place-items-center rounded-md border transition hover:-translate-y-px focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-teal-300",
      if(selected?,
        do: selected_class,
        else: "border-transparent text-slate-600 hover:border-slate-600 hover:text-slate-300"
      )
    ]
  end

  def release_year(%{release_year: year}) when is_integer(year), do: Integer.to_string(year)
  def release_year(_game), do: "Unknown year"

  def playtime_label(%{sources: sources}) when is_list(sources) do
    minutes =
      sources
      |> Enum.flat_map(& &1.library_items)
      |> Enum.map(&(&1.playtime_minutes || 0))
      |> Enum.max(fn -> 0 end)

    if minutes > 0, do: "#{Float.round(minutes / 60, 1)}h", else: "0h"
  end

  def playtime_label(_game), do: "0h"

  def status_label("backlog"), do: "Want to play"
  def status_label("playing"), do: "Playing"
  def status_label("completed"), do: "Completed"
  def status_label("dropped"), do: "Dropped"
  def status_label("not_played"), do: "Not played"

  def status_badge("completed") do
    "hidden rounded-full bg-emerald-400/10 px-2.5 py-1 text-center text-xs font-semibold text-emerald-200 ring-1 ring-emerald-400/20 sm:block"
  end

  def status_badge("dropped") do
    "hidden rounded-full bg-rose-400/10 px-2.5 py-1 text-center text-xs font-semibold text-rose-200 ring-1 ring-rose-400/20 sm:block"
  end

  def status_badge("playing") do
    "hidden rounded-full bg-sky-400/10 px-2.5 py-1 text-center text-xs font-semibold text-sky-200 ring-1 ring-sky-400/20 sm:block"
  end

  def status_badge("backlog") do
    "hidden rounded-full bg-violet-400/10 px-2.5 py-1 text-center text-xs font-semibold text-violet-200 ring-1 ring-violet-400/20 sm:block"
  end

  def status_badge(_not_played) do
    "hidden rounded-full bg-slate-800 px-2.5 py-1 text-center text-xs font-semibold text-slate-400 ring-1 ring-slate-700 sm:block"
  end

  def pluralize(1, singular, _plural), do: singular
  def pluralize(_count, _singular, plural), do: plural
end
