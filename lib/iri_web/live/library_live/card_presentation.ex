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

defmodule IriWeb.LibraryLive.CardPresentation do
  @moduledoc "Derived labels and badges for a canonical game card in the library browser."

  import IriWeb.CoreComponents, only: [rating_swatch: 1]

  alias Iri.Library.Playtime

  def owner_names(source) do
    source
    |> card_items()
    |> Enum.map(&(&1.provider_account.display_name || &1.provider_account.external_user_id))
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  # Playtime is the viewer's own only: filter the card's items down to the
  # accounts that count as theirs, so a shared game never shows another user's
  # hours.
  def playtime_label(source, current_user) do
    minutes =
      source
      |> card_items()
      |> Enum.filter(&Playtime.personal_account?(&1.provider_account, current_user))
      |> Enum.map(& &1.playtime_minutes)
      |> Enum.max(fn -> 0 end)

    if minutes > 0 do
      "#{Float.round(minutes / 60, 1)}h"
    end
  end

  def display_title(%{game: %{title: title}}), do: title
  def display_title(source), do: source.source_title

  def summary(%{game: %{summary: summary}}) when is_binary(summary), do: summary
  def summary(_source), do: nil

  def source_rating(%{game: %{rating: rating}}) when is_number(rating), do: rating
  def source_rating(_source), do: nil

  def personal_rating(%{game: %{user_states: [%{rating: rating} | _rest]}})
      when is_number(rating) and rating >= 1 and rating <= 5,
      do: rating

  def personal_rating(_source), do: nil

  def personal_rating_badge(rating) do
    ["grid size-6 place-items-center rounded-md", rating_swatch(rating)]
  end

  def rating_badge(rating) do
    color_classes =
      cond do
        rating >= 75 -> "bg-emerald-400/10 text-emerald-200"
        rating >= 50 -> "bg-amber-400/10 text-amber-200"
        true -> "bg-rose-400/10 text-rose-200"
      end

    [
      "flex shrink-0 items-center gap-1 rounded-md px-1.5 py-0.5 text-[0.65rem] font-semibold",
      color_classes
    ]
  end

  def cover_asset(%{game: %{media_assets: assets}}) do
    Enum.find(assets, &(&1.kind == "cover" and &1.cache_status == "ready"))
  end

  def cover_asset(_source), do: nil

  def preview_screenshots(%{game: %{media_assets: assets}}) do
    assets
    |> Enum.filter(&(&1.kind == "screenshot" and is_binary(&1.remote_url)))
    |> Enum.sort_by(& &1.position)
    |> Enum.take(4)
  end

  def preview_screenshots(_source), do: []

  def prominent_terms(%{game: %{terms: terms}}) do
    terms
    |> Enum.filter(&(&1.kind in ["genre", "theme", "game_mode"]))
    |> Enum.reject(&suppressed_term?/1)
    |> Iri.Library.TaxonomyTerm.deduplicate()
    |> Enum.sort_by(&{term_priority(Iri.Library.TaxonomyTerm.presentation_kind(&1)), &1.name})
    |> Enum.take(3)
  end

  def prominent_terms(_source), do: []

  def personal_state(%{game: %{user_states: [state | _rest]}}), do: state.state
  def personal_state(_source), do: nil

  def state_badge("completed"),
    do:
      "rounded-md bg-slate-950/85 px-2 py-1 text-[0.68rem] font-semibold text-emerald-200 ring-1 ring-emerald-400/30"

  def state_badge("dropped"),
    do:
      "rounded-md bg-slate-950/85 px-2 py-1 text-[0.68rem] font-semibold text-rose-200 ring-1 ring-rose-400/30"

  def state_badge("playing"),
    do:
      "rounded-md bg-slate-950/85 px-2 py-1 text-[0.68rem] font-semibold text-sky-200 ring-1 ring-sky-400/30"

  def state_badge("backlog"),
    do:
      "rounded-md bg-slate-950/85 px-2 py-1 text-[0.68rem] font-semibold text-violet-200 ring-1 ring-violet-400/30"

  def state_label("backlog"), do: "Want to play"
  def state_label("playing"), do: "Playing"
  def state_label("completed"), do: "Completed"
  def state_label("dropped"), do: "Dropped"

  def compatibility_badges(source) do
    sources = compatibility_sources(source)

    []
    |> maybe_badge(platform_label(sources), "bg-slate-800 text-slate-300")
    |> maybe_badge(controller_label(sources), "bg-slate-800 text-slate-300")
    |> maybe_badge(deck_label(sources), "bg-sky-400/10 text-sky-200")
    |> maybe_badge(protondb_label(sources), "bg-emerald-400/10 text-emerald-200")
    |> maybe_badge(vr_label(sources), "bg-slate-800 text-slate-300")
  end

  def source_providers(%{game: %{sources: sources}}) do
    sources
    |> Enum.filter(fn source -> Enum.any?(source.library_items, &visible_item?/1) end)
    |> Enum.map(&display_source_provider/1)
    |> Enum.uniq()
  end

  def source_providers(source), do: [display_source_provider(source)]

  def provider_badge(:steam),
    do:
      "rounded-md bg-slate-950/85 px-2 py-1 text-[0.65rem] font-semibold uppercase tracking-wide text-sky-200"

  def provider_badge(:gog),
    do:
      "rounded-md bg-slate-950/85 px-2 py-1 text-[0.65rem] font-semibold uppercase tracking-wide text-violet-200"

  def provider_badge(:custom),
    do:
      "rounded-md bg-slate-950/85 px-2 py-1 text-[0.65rem] font-semibold uppercase tracking-wide text-teal-200"

  def provider_badge(_provider),
    do:
      "rounded-md bg-slate-950/85 px-2 py-1 text-[0.65rem] font-semibold uppercase tracking-wide text-slate-200"

  def card_items(%{game: %{sources: sources}}) do
    sources
    |> Enum.flat_map(& &1.library_items)
    |> Enum.filter(&visible_item?/1)
  end

  def card_items(source), do: Enum.filter(source.library_items, &visible_item?/1)

  def fallback_gradient(_id), do: "from-slate-800 via-slate-900 to-slate-950"

  defp compatibility_sources(%{game: %{sources: sources}}) do
    Enum.filter(sources, fn source -> Enum.any?(source.library_items, &visible_item?/1) end)
  end

  defp compatibility_sources(source), do: [source]

  defp platform_label(sources) do
    labels =
      [{:available_windows, "Win"}, {:available_mac, "Mac"}, {:available_linux, "Linux"}]
      |> Enum.filter(fn {field, _label} -> Enum.any?(sources, &Map.get(&1, field)) end)
      |> Enum.map_join(" · ", &elem(&1, 1))

    if labels == "", do: nil, else: labels
  end

  defp controller_label(sources) do
    cond do
      Enum.any?(sources, &(&1.controller_support == "full")) -> "Controller"
      Enum.any?(sources, &(&1.controller_support == "partial")) -> "Controller partial"
      true -> nil
    end
  end

  defp deck_label(sources) do
    cond do
      Enum.any?(sources, &(&1.deck_compatibility == "verified")) -> "Deck verified"
      Enum.any?(sources, &(&1.deck_compatibility == "playable")) -> "Deck playable"
      true -> nil
    end
  end

  defp protondb_label(sources) do
    case Enum.find_value(sources, & &1.protondb_tier) do
      nil -> nil
      tier -> "ProtonDB #{String.capitalize(tier)}"
    end
  end

  defp vr_label(sources) do
    cond do
      Enum.any?(sources, &(&1.vr_support == "required")) -> "VR only"
      Enum.any?(sources, &(&1.vr_support == "supported")) -> "VR"
      true -> nil
    end
  end

  defp maybe_badge(badges, nil, _classes), do: badges
  defp maybe_badge(badges, label, classes), do: badges ++ [{label, classes}]

  defp suppressed_term?(%{kind: "game_mode", name: name}),
    do: String.downcase(name) == "battle royale"

  defp suppressed_term?(_term), do: false

  defp display_source_provider(%{provider: :igdb, library_items: items}) do
    if Enum.any?(items, &(&1.provider_account.provider == :custom)), do: :custom, else: :igdb
  end

  defp display_source_provider(source), do: source.provider

  defp term_priority("genre"), do: 0
  defp term_priority("theme"), do: 1
  defp term_priority(_kind), do: 2

  defp visible_item?(item) do
    is_nil(item.removed_at) and item.provider_account.enabled
  end
end
