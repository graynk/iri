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

defmodule IriWeb.GameLive.Presentation do
  @moduledoc "Presentation helpers for the canonical game detail page."

  import IriWeb.CoreComponents,
    only: [format_rating_value: 1, rating_face_index: 1, rating_swatch: 1]

  import Phoenix.Component, only: [to_form: 2]

  alias Iri.Integrations.Steam.ManualLibrary
  alias Iri.Library.{Personalization, Playtime, StoreLink, TaxonomyTerm}
  alias Iri.Media.Policy

  @source_badge_base "inline-flex min-h-6 items-center rounded-md px-2 text-xs font-semibold uppercase leading-none tracking-wide ring-1"

  def collection_picker_label(memberships) do
    case Enum.count(memberships, & &1.member?) do
      0 -> "Add to collections"
      1 -> "In 1 collection"
      count -> "In #{count} collections"
    end
  end

  def state_button_class(game_state, state) do
    selected? = game_state && game_state.state == state

    [
      "inline-flex min-h-9 items-center gap-1.5 rounded-lg border px-3 py-2 text-xs font-semibold transition",
      selected? && state == "completed" &&
        "border-emerald-400/40 bg-emerald-400/15 text-emerald-200",
      selected? && state == "dropped" && "border-rose-400/40 bg-rose-400/15 text-rose-200",
      selected? && state == "playing" && "border-sky-400/40 bg-sky-400/15 text-sky-200",
      selected? && state == "backlog" &&
        "border-violet-400/40 bg-violet-400/15 text-violet-200",
      !selected? && "border-slate-700 text-slate-400 hover:border-slate-500 hover:text-slate-200"
    ]
  end

  def completion_state(%{state: state})
      when state in ["backlog", "playing", "completed", "dropped"],
      do: state

  def completion_state(_game_state), do: nil

  def completion_state_label("backlog"), do: "Want to play"
  def completion_state_label("playing"), do: "Playing"
  def completion_state_label("completed"), do: "Completed"
  def completion_state_label("dropped"), do: "Dropped"

  def current_rating(%{rating: rating})
      when is_number(rating) and rating >= 1 and rating <= 5,
      do: rating

  def current_rating(_game_state), do: nil

  def rating_form(game_state) do
    value =
      game_state
      |> current_rating()
      |> then(&if(&1, do: format_rating_value(&1), else: ""))

    to_form(%{"value" => value}, as: :rating)
  end

  def note_form(game_state) do
    game_state
    |> Personalization.change_note()
    |> to_form(as: :note)
  end

  def rating_option_class(selected?, rating) do
    selected_class = rating_swatch(rating)

    [
      "grid size-10 place-items-center overflow-hidden rounded-xl border transition",
      if(selected?,
        do: selected_class,
        else:
          "border-slate-700 text-slate-500 group-hover:border-slate-500 group-hover:text-slate-200"
      )
    ]
  end

  def rating_groups do
    [
      {1, [1.0]},
      {2, [1.5, 2.0]},
      {3, [2.5, 3.0]},
      {4, [3.5, 4.0]},
      {5, [4.5, 5.0]}
    ]
  end

  def rating_face_value(rating, face) when is_number(rating) do
    if rating_face_index(rating) == face, do: rating, else: face
  end

  def rating_face_value(_rating, face), do: face

  def rating_input_id(rating),
    do: "rate-game-#{String.replace(format_rating_value(rating), ".", "-")}"

  # The named peers (`peer/half`, `peer/full`) drive the hover-preview overlays:
  # hovering the left half previews a half icon, the right half a full one.
  def rating_hit_area_class([_single_rating], _rating) do
    "peer/full absolute inset-0 z-10 cursor-pointer rounded-xl"
  end

  def rating_hit_area_class([first_rating, _second_rating], rating)
      when rating == first_rating do
    "peer/half absolute inset-y-0 left-0 z-10 w-1/2 cursor-pointer rounded-l-xl"
  end

  def rating_hit_area_class([_first_rating, _second_rating], _rating) do
    "peer/full absolute inset-y-0 right-0 z-10 w-1/2 cursor-pointer rounded-r-xl"
  end

  def rating_selected?(current_rating, face) when is_number(current_rating),
    do: rating_face_index(current_rating) == face

  def rating_selected?(_current_rating, _face), do: false

  def cover_asset(game, user) do
    if Policy.hidden?(game, user) do
      nil
    else
      Enum.find(game.media_assets, &(&1.kind == "cover" and &1.cache_status == "ready"))
    end
  end

  def screenshots(game, user) do
    if Policy.hidden?(game, user),
      do: [],
      else: Enum.filter(game.media_assets, &(&1.kind == "screenshot"))
  end

  def videos(game), do: Enum.filter(game.media_assets, &(&1.kind == "video"))

  def rating_source(%{vndb_id: vndb_id}) when is_binary(vndb_id), do: "VNDB"
  def rating_source(_game), do: "IGDB"

  def visible_terms(game) do
    game.terms
    |> Enum.reject(fn term ->
      term.kind == "game_mode" and String.downcase(term.name) == "battle royale"
    end)
    |> Iri.Library.TaxonomyTerm.deduplicate()
    |> Enum.sort_by(&{Iri.Library.TaxonomyTerm.presentation_kind(&1), &1.name})
  end

  def genre_terms(game) do
    Enum.filter(visible_terms(game), &(TaxonomyTerm.presentation_kind(&1) == "genre"))
  end

  def tag_terms(game) do
    Enum.reject(visible_terms(game), &(TaxonomyTerm.presentation_kind(&1) == "genre"))
  end

  def term_label(term), do: TaxonomyTerm.display_name(term)

  def company_role_label(%{role: "developer"}), do: "Developed by"
  def company_role_label(%{role: "publisher"}), do: "Published by"
  def company_role_label(_relation), do: "By"

  def video_embed_url(%{remote_url: remote_url}) do
    video_id =
      remote_url |> URI.parse() |> then(&URI.decode_query(&1.query || "")) |> Map.get("v")

    if video_id do
      "https://www.youtube-nocookie.com/embed/#{URI.encode(video_id)}?autoplay=1&rel=0"
    else
      remote_url
    end
  end

  def owned_sources(game),
    do:
      Enum.filter(
        game.sources,
        &Enum.any?(&1.library_items, fn item ->
          is_nil(item.removed_at) and item.provider_account.enabled
        end)
      )

  def custom_owned?(game, user_id) do
    Enum.any?(game.sources, fn source ->
      source.provider == :igdb and
        Enum.any?(source.library_items, fn item ->
          item.provider_account.provider == :custom and
            item.provider_account.owner_user_id == user_id and is_nil(item.removed_at)
        end)
    end)
  end

  def manual_steam_sources(game, user) do
    game
    |> owned_sources()
    |> Enum.filter(fn source ->
      source.provider == :steam and
        Enum.any?(source.library_items, fn item ->
          Playtime.personal_account?(item.provider_account, user) and
            ManualLibrary.manual_item?(item)
        end)
    end)
    |> Enum.uniq_by(& &1.id)
  end

  def display_source_provider(%{provider: :igdb, library_items: items}) do
    if Enum.any?(items, &(&1.provider_account.provider == :custom)), do: :custom, else: :igdb
  end

  def display_source_provider(source), do: source.provider

  def steam_install_sources(game) do
    game
    |> owned_sources()
    |> Enum.filter(&(&1.provider == :steam and Regex.match?(~r/^\d+$/, &1.external_id)))
    |> Enum.uniq_by(& &1.external_id)
  end

  # The same store links the collection exports carry, shown on the page.
  def store_links(game) do
    game
    |> owned_sources()
    |> StoreLink.for_sources()
  end

  def store_link_slug(%{store: store}) do
    store |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
  end

  def compatibility_details(game) do
    sources = owned_sources(game)

    []
    |> add_detail(platform_detail(sources), "bg-slate-800 text-slate-300 ring-slate-700")
    |> add_detail(
      controller_detail(sources),
      "bg-slate-800 text-slate-300 ring-slate-700"
    )
    |> add_detail(deck_detail(sources), "bg-sky-400/10 text-sky-200 ring-sky-400/20")
    |> add_detail(vr_detail(sources), "bg-slate-800 text-slate-300 ring-slate-700")
  end

  def protondb_sources(game) do
    game
    |> owned_sources()
    |> Enum.filter(&(&1.provider == :steam and is_binary(&1.protondb_tier)))
    |> Enum.uniq_by(& &1.external_id)
  end

  # Match library sorting: a user's playtime is the highest value reported by
  # one of their eligible accounts, never a shared account's value or a sum
  # across storefronts.
  def personal_playtime_label(game, current_user) do
    minutes =
      game
      |> owned_sources()
      |> Enum.flat_map(& &1.library_items)
      |> Enum.filter(&Playtime.personal_account?(&1.provider_account, current_user))
      |> Enum.map(&(&1.playtime_minutes || 0))
      |> Enum.max(fn -> 0 end)

    if minutes > 0, do: format_hour_duration(minutes / 60)
  end

  def time_to_beat_label(%{
        time_to_beat_main_seconds: main_seconds,
        time_to_beat_extra_seconds: extra_seconds
      })
      when is_integer(main_seconds) and main_seconds > 0 and is_integer(extra_seconds) and
             extra_seconds > 0 do
    "#{format_hours(main_seconds / 3_600)}-#{format_hours(extra_seconds / 3_600)} hours"
  end

  def time_to_beat_label(_game), do: nil

  def playtime_block?(game, current_user) do
    not is_nil(personal_playtime_label(game, current_user)) or
      not is_nil(time_to_beat_label(game))
  end

  def release_label(%{release_date: %Date{} = date}), do: Calendar.strftime(date, "%B %Y")
  def release_label(_game), do: "Release date unavailable"

  def detail_rating_badge(rating) do
    color_classes =
      cond do
        rating >= 75 -> "bg-emerald-400/10 text-emerald-200 ring-emerald-400/20"
        rating >= 50 -> "bg-amber-400/10 text-amber-200 ring-amber-400/20"
        true -> "bg-rose-400/10 text-rose-200 ring-rose-400/20"
      end

    [
      "inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-xs font-semibold ring-1",
      color_classes
    ]
  end

  # inline-flex + items-center + leading-none keeps the uppercase label centred
  # in the pill; without it the descender-free caps sit high on mobile.
  def source_badge(:steam),
    do: "#{@source_badge_base} bg-sky-400/10 text-sky-200 ring-sky-400/20"

  def source_badge(:gog),
    do: "#{@source_badge_base} bg-violet-400/10 text-violet-200 ring-violet-400/20"

  def source_badge(:custom),
    do: "#{@source_badge_base} bg-teal-400/10 text-teal-200 ring-teal-400/20"

  def source_badge(_provider),
    do:
      "inline-flex min-h-6 items-center rounded-md bg-slate-800 px-2 text-xs leading-none text-slate-300"

  defp platform_detail(sources) do
    platforms =
      [{:available_windows, "Windows"}, {:available_mac, "macOS"}, {:available_linux, "Linux"}]
      |> Enum.filter(fn {field, _label} -> Enum.any?(sources, &Map.get(&1, field)) end)
      |> Enum.map_join(" · ", &elem(&1, 1))

    if platforms == "", do: nil, else: platforms
  end

  defp controller_detail(sources) do
    cond do
      Enum.any?(sources, &(&1.controller_support == "full")) -> "Full controller support"
      Enum.any?(sources, &(&1.controller_support == "partial")) -> "Partial controller support"
      true -> nil
    end
  end

  defp deck_detail(sources) do
    cond do
      Enum.any?(sources, &(&1.deck_compatibility == "verified")) -> "Steam Deck verified"
      Enum.any?(sources, &(&1.deck_compatibility == "playable")) -> "Steam Deck playable"
      Enum.any?(sources, &(&1.deck_compatibility == "unsupported")) -> "Steam Deck unsupported"
      true -> nil
    end
  end

  defp vr_detail(sources) do
    cond do
      Enum.any?(sources, &(&1.vr_support == "required")) -> "VR required"
      Enum.any?(sources, &(&1.vr_support == "supported")) -> "VR supported"
      true -> nil
    end
  end

  defp add_detail(details, nil, _classes), do: details
  defp add_detail(details, label, classes), do: details ++ [{label, classes}]

  defp format_hours(hours) do
    rounded = Float.round(hours, 1)

    if rounded == trunc(rounded) do
      Integer.to_string(trunc(rounded))
    else
      :erlang.float_to_binary(rounded, decimals: 1)
    end
  end

  defp format_hour_duration(hours) do
    formatted = format_hours(hours)
    "#{formatted} #{if(formatted == "1", do: "hour", else: "hours")}"
  end
end
