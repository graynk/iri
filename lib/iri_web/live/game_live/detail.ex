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

defmodule IriWeb.GameLive.Detail do
  @moduledoc false

  use IriWeb, :html

  import IriWeb.GameLive.Presentation
  import IriWeb.MediaAssetSource, only: [screenshot_url: 1]

  alias Iri.Media.Policy

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto w-full max-w-[72.5rem]">
        <section
          id="game-detail-layout"
          class="grid grid-cols-1 items-start gap-y-5 lg:grid-cols-[17.5rem_minmax(0,1fr)] lg:gap-x-12"
        >
          <aside
            id="game-personal-rail"
            class="contents lg:sticky lg:top-20 lg:col-start-1 lg:row-start-1 lg:flex lg:flex-col lg:gap-4"
          >
            <div
              id="game-media-column"
              class="order-1 col-start-1 row-start-1 w-full overflow-hidden rounded-xl border border-slate-700 bg-slate-900 shadow-xl shadow-black/30 lg:order-none lg:col-auto lg:row-auto"
            >
              <div class="relative aspect-[3/4]">
                <img
                  :if={@cover}
                  id="game-cover"
                  src={~p"/media/#{@cover.id}"}
                  alt={"Cover for #{@game.title}"}
                  data-sensitive-media={
                    if(@sensitive_media_blurred? and not @sensitive_media_revealed?, do: "blurred")
                  }
                  class={[
                    "size-full object-contain transition",
                    @sensitive_media_blurred? and not @sensitive_media_revealed? and
                      "sensitive-media-blur"
                  ]}
                />
                <div
                  :if={!@cover}
                  class="grid size-full place-items-center bg-slate-900 text-4xl font-semibold text-slate-600 lg:text-7xl"
                >
                  {@game.title |> String.first() |> String.upcase()}
                </div>
                <button
                  :if={
                    not is_nil(@cover) and @sensitive_media_blurred? and
                      not @sensitive_media_revealed?
                  }
                  id="reveal-sensitive-cover"
                  type="button"
                  phx-click="reveal_sensitive_media"
                  class="absolute inset-0 cursor-pointer bg-transparent focus:outline-none focus:ring-2 focus:ring-inset focus:ring-teal-300"
                  aria-label="Reveal sensitive media on this page"
                />
              </div>
            </div>

            <section
              id="my-game-log"
              aria-labelledby="my-game-log-title"
              class="order-3 col-span-1 col-start-1 row-start-3 flex min-w-0 flex-col gap-4 rounded-xl border border-slate-800 bg-slate-900 p-4 lg:order-none lg:col-auto lg:row-auto"
            >
              <h2
                id="my-game-log-title"
                class="text-[11px] font-semibold uppercase tracking-[0.12em] text-slate-500"
              >
                My log
              </h2>

              <div
                id="game-state-controls"
                role="group"
                aria-label="Completion status"
                class="grid grid-cols-2 gap-1.5"
              >
                <button
                  id="mark-game-playing"
                  type="button"
                  phx-click="set_game_state"
                  phx-value-state="playing"
                  aria-pressed={to_string(completion_state(@game_state) == "playing")}
                  class={["w-full justify-center", state_button_class(@game_state, "playing")]}
                >
                  <.icon name="hero-play-circle" class="size-4" /> Playing
                </button>
                <button
                  id="mark-game-want-to-play"
                  type="button"
                  phx-click="set_game_state"
                  phx-value-state="backlog"
                  aria-pressed={to_string(completion_state(@game_state) == "backlog")}
                  class={["w-full justify-center", state_button_class(@game_state, "backlog")]}
                >
                  <.icon name="hero-bookmark" class="size-4" /> Want to play
                </button>
                <button
                  id="mark-game-completed"
                  type="button"
                  phx-click="set_game_state"
                  phx-value-state="completed"
                  aria-pressed={to_string(completion_state(@game_state) == "completed")}
                  class={["w-full justify-center", state_button_class(@game_state, "completed")]}
                >
                  <.icon name="hero-check-circle" class="size-4" /> Completed
                </button>
                <button
                  id="mark-game-dropped"
                  type="button"
                  phx-click="set_game_state"
                  phx-value-state="dropped"
                  aria-pressed={to_string(completion_state(@game_state) == "dropped")}
                  class={["w-full justify-center", state_button_class(@game_state, "dropped")]}
                >
                  <.icon name="hero-no-symbol" class="size-4" /> Dropped
                </button>
              </div>

              <.form for={@rating_form} id="personal-rating" phx-change="set_rating">
                <fieldset>
                  <legend class="text-[11px] font-semibold uppercase tracking-[0.12em] text-slate-500">
                    My rating
                  </legend>
                  <div class="mt-2.5 grid grid-cols-5 gap-1.5">
                    <div
                      :for={{face, ratings} <- rating_groups()}
                      class={[
                        rating_option_class(
                          rating_selected?(current_rating(@game_state), face),
                          face
                        ),
                        "group/cell relative w-full focus-within:outline-2 focus-within:outline-offset-2 focus-within:outline-teal-300"
                      ]}
                    >
                      <.rating_face
                        rating={rating_face_value(current_rating(@game_state), face)}
                        class="size-5"
                      />
                      <label
                        :for={rating <- ratings}
                        for={rating_input_id(rating)}
                        title={"#{format_rating_value(rating)} out of 5: #{rating_label(rating)}"}
                        class={rating_hit_area_class(ratings, rating)}
                      >
                        <input
                          id={rating_input_id(rating)}
                          type="radio"
                          name={@rating_form[:value].name}
                          value={format_rating_value(rating)}
                          checked={current_rating(@game_state) == rating}
                          aria-label={
                            "#{format_rating_value(rating)} out of 5: #{rating_label(rating)}"
                          }
                          class="sr-only"
                        />
                      </label>
                      <span
                        aria-hidden="true"
                        class="pointer-events-none absolute inset-y-0 left-0 z-[1] hidden w-1/2 rounded-l-xl bg-teal-300/30 peer-hover/half:block"
                      ></span>
                      <span
                        aria-hidden="true"
                        class="pointer-events-none absolute inset-0 z-[1] hidden rounded-xl bg-teal-300/30 peer-hover/full:block"
                      ></span>
                    </div>
                  </div>
                  <div class="mt-2 flex min-h-5 items-center justify-between gap-3">
                    <span id="rating-feedback" aria-live="polite" class="text-xs text-teal-300">
                      {@rating_message}
                    </span>
                    <button
                      :if={current_rating(@game_state)}
                      id="clear-personal-rating"
                      type="button"
                      phx-click="clear_rating"
                      class="text-xs font-medium text-slate-500 transition hover:text-slate-200"
                    >
                      Clear rating
                    </button>
                  </div>
                </fieldset>
              </.form>

              <div
                :if={playtime_block?(@game, @current_scope.user)}
                id="game-playtime"
                class="flex flex-col gap-2 border-t border-slate-800 pt-3"
              >
                <div
                  :if={personal_playtime_label(@game, @current_scope.user)}
                  id="my-playtime"
                  class="flex items-baseline justify-between gap-3"
                >
                  <span class="text-xs text-slate-400">Playtime</span>
                  <span class="text-sm font-medium text-slate-100">
                    {personal_playtime_label(@game, @current_scope.user)}
                  </span>
                </div>
                <div
                  :if={time_to_beat_label(@game)}
                  id="game-time-to-beat"
                  class="flex items-baseline justify-between gap-3"
                >
                  <span class="text-xs text-slate-400">Time to beat</span>
                  <span class="text-sm font-medium text-slate-300">
                    {time_to_beat_label(@game)}
                  </span>
                </div>
              </div>

              <div id="personal-note">
                <div class="mb-2 flex min-h-5 items-center justify-between gap-3">
                  <h3 class="text-[11px] font-semibold uppercase tracking-[0.12em] text-slate-500">
                    Note
                  </h3>
                  <span id="note-feedback" aria-live="polite" class="text-xs text-teal-300">
                    {@note_message}
                  </span>
                </div>
                <.form for={@note_form} id="personal-note-form">
                  <.input
                    field={@note_form[:notes]}
                    id="personal-note-input"
                    type="textarea"
                    maxlength="10000"
                    rows="5"
                    placeholder="Private note about this game…"
                    aria-label="Private note about this game"
                    phx-blur="save_note"
                    class="min-h-28 w-full resize-y rounded-lg border border-slate-700 bg-slate-950/60 px-3 py-2.5 text-base leading-6 text-slate-100 outline-none transition placeholder:text-slate-600 focus:border-teal-300 focus:ring-2 focus:ring-teal-300/20 sm:text-sm"
                  />
                </.form>
              </div>

              <details id="game-collection-picker" class="group relative">
                <summary class="flex min-h-10 w-full cursor-pointer list-none items-center justify-center gap-2 rounded-lg border border-teal-400/30 bg-teal-400/5 px-3 py-2 text-sm font-semibold text-teal-200 transition hover:bg-teal-400/10 [&::-webkit-details-marker]:hidden">
                  <.icon name="hero-bookmark-square" class="size-4" />
                  {collection_picker_label(@collection_memberships)}
                  <.icon
                    name="hero-chevron-down"
                    class="size-3.5 text-teal-300/70 transition group-open:rotate-180"
                  />
                </summary>
                <div class="absolute left-0 top-full z-40 mt-2 w-full min-w-60 overflow-hidden rounded-xl border border-slate-700 bg-slate-900 shadow-2xl shadow-black/50">
                  <%= if @collection_memberships == [] do %>
                    <div id="game-collection-picker-empty" class="p-4">
                      <p class="text-sm text-slate-400">You do not have any collections yet.</p>
                      <.link
                        navigate={~p"/collections/new"}
                        class="mt-3 inline-flex min-h-9 items-center gap-1.5 rounded-lg border border-teal-400/30 px-3 py-1.5 text-xs font-semibold text-teal-200 transition hover:bg-teal-400/10"
                      >
                        <.icon name="hero-plus" class="size-3.5" /> Create collection
                      </.link>
                    </div>
                  <% else %>
                    <.form
                      for={@collection_form}
                      id="game-collection-form"
                      phx-submit="update_collections"
                    >
                      <input type="hidden" name="collections[collection_ids][]" value="" />
                      <div class="max-h-72 overflow-y-auto p-2">
                        <label
                          :for={membership <- @collection_memberships}
                          for={"game-collection-#{membership.id}"}
                          class="flex min-h-11 cursor-pointer items-center gap-3 rounded-lg px-3 py-2 text-sm text-slate-200 transition hover:bg-slate-800"
                        >
                          <input
                            id={"game-collection-#{membership.id}"}
                            type="checkbox"
                            name="collections[collection_ids][]"
                            value={membership.id}
                            checked={membership.member?}
                            class="size-4 rounded border-slate-600 bg-slate-950 text-teal-300 focus:ring-teal-300"
                          />
                          <span class="min-w-0 flex-1 truncate">{membership.name}</span>
                        </label>
                      </div>
                      <div class="flex items-center justify-between gap-3 border-t border-slate-800 p-3">
                        <.link
                          navigate={~p"/collections/new"}
                          class="text-xs font-medium text-slate-500 transition hover:text-teal-200"
                        >
                          New collection
                        </.link>
                        <button
                          id="save-game-collections"
                          type="submit"
                          phx-disable-with="Saving…"
                          class="inline-flex min-h-9 items-center rounded-lg bg-teal-300 px-3 py-1.5 text-xs font-semibold text-on-accent transition hover:bg-teal-200"
                        >
                          Save
                        </button>
                      </div>
                    </.form>
                  <% end %>
                </div>
              </details>

              <div
                id="game-log-footer"
                class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 border-t border-slate-800 pt-2 text-[11px] text-slate-500"
              >
                <button
                  :if={
                    owned_sources(@game) != [] and
                      (@current_scope.role == :admin or
                         custom_owned?(@game, @current_scope.user.id))
                  }
                  id="fix-match"
                  type="button"
                  phx-click="fix_match"
                  data-confirm="Change this game's match? Its current match is cleared until you choose a new one."
                  class="min-h-8 transition hover:text-teal-200"
                >
                  Fix match
                </button>
                <button
                  :if={custom_owned?(@game, @current_scope.user.id)}
                  id="remove-custom-game"
                  type="button"
                  phx-click="remove_custom_game"
                  data-confirm="Remove this custom game from your library?"
                  class="min-h-8 transition hover:text-rose-300"
                >
                  Remove custom game
                </button>
                <button
                  :for={source <- manual_steam_sources(@game, @current_scope.user)}
                  id={"remove-manual-steam-#{source.id}"}
                  type="button"
                  phx-click="remove_manual_steam_game"
                  phx-value-source_id={source.id}
                  data-confirm="Remove this manually added Steam game from your library?"
                  class="min-h-8 transition hover:text-rose-300"
                >
                  Remove manual entry
                </button>
                <div
                  :if={@current_scope.role == :admin}
                  id="sensitive-media-admin-control"
                  class="contents"
                >
                  <button
                    :if={Policy.sensitive?(@game)}
                    id="mark-game-not-sensitive"
                    type="button"
                    phx-click="mark_game_not_sensitive"
                    data-confirm="Mark this game as non-sensitive for everyone on this server?"
                    class="min-h-8 transition hover:text-slate-300"
                  >
                    Mark as non-sensitive
                  </button>
                  <button
                    :if={!Policy.sensitive?(@game)}
                    id="mark-game-sensitive"
                    type="button"
                    phx-click="mark_game_sensitive"
                    data-confirm="Mark this game as NSFW for everyone on this server?"
                    class="min-h-8 transition hover:text-slate-300"
                  >
                    Mark as NSFW
                  </button>
                </div>
              </div>
            </section>
          </aside>

          <div
            id="game-content-column"
            class="contents lg:col-start-2 lg:row-start-1 lg:flex lg:min-w-0 lg:flex-col lg:gap-11"
          >
            <header
              id="game-title-block"
              class="order-2 col-span-1 col-start-1 row-start-2 flex min-w-0 flex-col gap-2.5 self-start py-1 lg:self-stretch lg:order-none lg:col-auto lg:row-auto lg:gap-3.5 lg:pt-5"
            >
              <div
                :if={owned_sources(@game) != []}
                id="game-sources"
                class="flex flex-wrap gap-2"
              >
                <span
                  :for={source <- owned_sources(@game)}
                  class={source_badge(display_source_provider(source))}
                >
                  {display_source_provider(source)}
                </span>
              </div>

              <div class="flex min-w-0 flex-col items-start gap-3 xl:flex-row xl:justify-between">
                <h1
                  id="game-title"
                  class="min-w-0 text-3xl font-semibold leading-none tracking-tight text-heading sm:text-4xl lg:text-5xl"
                >
                  {@game.title}
                </h1>
                <div
                  id="game-primary-actions"
                  class="grid w-full grid-cols-2 items-center gap-2 xl:flex xl:w-auto xl:shrink-0 xl:justify-end"
                >
                  <a
                    :for={source <- steam_install_sources(@game)}
                    id={"install-steam-#{source.external_id}"}
                    href={"steam://install/#{source.external_id}"}
                    class="inline-flex min-h-10 min-w-0 items-center justify-center gap-2 whitespace-nowrap rounded-xl border border-sky-400/30 bg-sky-400/10 px-2 py-2 text-xs font-semibold text-sky-200 transition hover:bg-sky-400/20 sm:px-3 sm:text-sm"
                  >
                    <.icon name="hero-arrow-down-tray" class="size-4" /> Install with Steam
                  </a>
                  <a
                    :for={link <- store_links(@game)}
                    id={"store-link-#{store_link_slug(link)}"}
                    href={link.url}
                    target="_blank"
                    rel="noreferrer"
                    class="inline-flex min-h-10 min-w-0 items-center justify-center gap-2 whitespace-nowrap rounded-xl border border-slate-700 px-2 py-2 text-xs font-semibold text-slate-200 transition hover:border-slate-500 hover:bg-slate-800 sm:px-3 sm:text-sm"
                  >
                    {link.store}
                    <.icon name="hero-arrow-top-right-on-square" class="size-4" />
                  </a>
                </div>
              </div>

              <div
                id="game-byline"
                class="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-slate-500 sm:text-sm"
              >
                <span>{release_label(@game)}</span>
                <%= for relation <- @game.game_companies do %>
                  <span aria-hidden="true" class="text-slate-700">·</span>
                  <span>
                    {company_role_label(relation)}
                    <.link
                      id={"game-company-#{relation.id}"}
                      navigate={~p"/companies/#{relation.company.id}"}
                      class="ml-1 text-slate-300 transition hover:text-teal-200"
                    >
                      {relation.company.name}
                    </.link>
                  </span>
                <% end %>
                <span :if={is_number(@game.rating)} aria-hidden="true" class="text-slate-700">
                  ·
                </span>
                <span
                  :if={is_number(@game.rating)}
                  id="game-metadata-rating"
                  class={detail_rating_badge(@game.rating)}
                >
                  <.icon name="hero-hand-thumb-up" class="size-3.5" />
                  {round(@game.rating)}% {rating_source(@game)}
                </span>
              </div>

              <div
                :if={compatibility_details(@game) != [] or protondb_sources(@game) != []}
                id="game-compatibility"
                class="flex flex-wrap gap-2"
              >
                <span
                  :for={{label, classes} <- compatibility_details(@game)}
                  class={["rounded-lg px-2.5 py-1.5 text-xs font-semibold ring-1", classes]}
                >
                  {label}
                </span>
                <a
                  :for={source <- protondb_sources(@game)}
                  id={"protondb-#{source.external_id}"}
                  href={"https://www.protondb.com/app/#{source.external_id}"}
                  target="_blank"
                  rel="noreferrer"
                  class="rounded-lg bg-emerald-400/10 px-2.5 py-1.5 text-xs font-semibold text-emerald-200 ring-1 ring-emerald-400/20 transition hover:bg-emerald-400/20"
                >
                  ProtonDB {String.capitalize(source.protondb_tier)}
                </a>
              </div>
            </header>

            <section
              id="game-about"
              aria-labelledby="game-about-title"
              class="order-4 col-span-1 flex min-w-0 flex-col gap-3 lg:order-none lg:col-auto"
            >
              <h2
                id="game-about-title"
                class="text-[11px] font-semibold uppercase tracking-[0.12em] text-slate-500"
              >
                About
              </h2>
              <p
                :if={@game.summary}
                class="text-sm leading-7 text-slate-300 sm:text-base"
              >
                {@game.summary}
              </p>
              <p :if={!@game.summary} class="text-sm text-slate-500">
                No description is available from the metadata provider.
              </p>
            </section>

            <section
              :if={@screenshots != []}
              id="game-screenshots"
              aria-labelledby="game-screenshots-title"
              class="order-5 col-span-1 min-w-0 lg:order-none lg:col-auto"
            >
              <h2
                id="game-screenshots-title"
                class="text-[11px] font-semibold uppercase tracking-[0.12em] text-slate-500"
              >
                Screenshots <span class="font-mono tracking-normal">· {length(@screenshots)}</span>
              </h2>
              <div
                id="game-screenshot-strip"
                class="media-carousel-track mt-3 flex snap-x gap-3 overflow-x-auto pb-2"
              >
                <button
                  :for={{asset, index} <- Enum.with_index(@screenshots)}
                  id={"open-screenshot-#{index}"}
                  type="button"
                  phx-click={
                    if(@sensitive_media_blurred? and not @sensitive_media_revealed?,
                      do: "reveal_sensitive_media",
                      else: JS.push_focus() |> JS.push("show_screenshot")
                    )
                  }
                  phx-value-index={index}
                  class="group relative aspect-video w-[15.5rem] shrink-0 snap-start overflow-hidden rounded-xl border border-slate-800 bg-slate-900 text-left transition hover:border-teal-300 hover:ring-1 hover:ring-teal-300 focus:outline-none focus:ring-2 focus:ring-teal-300 sm:w-72"
                >
                  <img
                    src={screenshot_url(asset)}
                    alt={"Screenshot from #{@game.title}"}
                    loading="lazy"
                    data-sensitive-media={
                      if(@sensitive_media_blurred? and not @sensitive_media_revealed?,
                        do: "blurred"
                      )
                    }
                    class={[
                      "size-full object-cover",
                      @sensitive_media_blurred? and not @sensitive_media_revealed? and
                        "sensitive-media-blur"
                    ]}
                  />
                </button>
              </div>
            </section>

            <section
              :if={videos(@game) != []}
              id="game-trailers"
              aria-labelledby="game-trailers-title"
              class="order-6 col-span-1 min-w-0 lg:order-none lg:col-auto"
            >
              <h2
                id="game-trailers-title"
                class="text-[11px] font-semibold uppercase tracking-[0.12em] text-slate-500"
              >
                Trailers <span class="font-mono tracking-normal">· {length(videos(@game))}</span>
              </h2>
              <div class="mt-3 flex flex-wrap gap-2.5">
                <button
                  :for={{_asset, index} <- Enum.with_index(videos(@game), 1)}
                  id={"load-trailer-#{index - 1}"}
                  type="button"
                  phx-click={JS.push_focus() |> JS.push("load_trailer")}
                  phx-value-index={index - 1}
                  class="inline-flex min-h-11 items-center gap-2 rounded-xl border border-slate-700 px-4 py-2.5 text-sm font-semibold text-slate-300 transition hover:border-teal-400/50 hover:bg-teal-400/10 hover:text-teal-100 focus:outline-none focus:ring-2 focus:ring-teal-300"
                >
                  <.icon name="hero-play" class="size-4" /> Trailer {index}
                </button>
              </div>
            </section>

            <section
              :if={visible_terms(@game) != []}
              id="game-taxonomy"
              class="order-7 col-span-1 flex min-w-0 flex-col gap-3 lg:order-none lg:col-auto"
            >
              <div :if={genre_terms(@game) != []} id="game-genres">
                <h2 class="text-[11px] font-semibold uppercase tracking-[0.12em] text-slate-500">
                  Genres
                </h2>
                <div class="mt-3 flex flex-wrap gap-1.5">
                  <span
                    :for={term <- genre_terms(@game)}
                    class="inline-flex min-h-7 items-center rounded-lg bg-slate-800 px-2.5 py-1.5 text-xs font-semibold text-slate-300 ring-1 ring-slate-700"
                  >
                    {term_label(term)}
                  </span>
                </div>
              </div>

              <details
                :if={genre_terms(@game) != [] and tag_terms(@game) != []}
                id="game-tags"
                class="group"
              >
                <summary class="inline-flex min-h-9 cursor-pointer list-none items-center gap-1.5 text-xs text-slate-500 transition hover:text-slate-300 [&::-webkit-details-marker]:hidden">
                  <.icon
                    name="hero-chevron-down"
                    class="size-3.5 transition group-open:rotate-180"
                  />
                  {length(tag_terms(@game))} more {if length(tag_terms(@game)) == 1,
                    do: "tag",
                    else: "tags"}
                </summary>
                <div class="mt-2 flex flex-wrap gap-1.5">
                  <span
                    :for={term <- tag_terms(@game)}
                    class="inline-flex min-h-7 items-center rounded-lg bg-slate-900 px-2.5 py-1.5 text-xs font-semibold text-slate-500 ring-1 ring-slate-800"
                  >
                    {term_label(term)}
                  </span>
                </div>
              </details>

              <div :if={genre_terms(@game) == [] and tag_terms(@game) != []} id="game-tags">
                <h2 class="text-[11px] font-semibold uppercase tracking-[0.12em] text-slate-500">
                  Tags
                </h2>
                <div class="mt-3 flex flex-wrap gap-1.5">
                  <span
                    :for={term <- tag_terms(@game)}
                    class="inline-flex min-h-7 items-center rounded-lg bg-slate-900 px-2.5 py-1.5 text-xs font-semibold text-slate-500 ring-1 ring-slate-800"
                  >
                    {term_label(term)}
                  </span>
                </div>
              </div>
            </section>
          </div>
        </section>

        <div
          :if={!is_nil(@screenshot_index)}
          id="screenshot-viewer"
          role="dialog"
          aria-modal="true"
          aria-label={"Screenshot from #{@game.title}"}
          phx-window-keydown="close_screenshot"
          phx-key="escape"
          phx-remove={JS.pop_focus()}
          class="fixed inset-0 z-50 bg-slate-950/95 backdrop-blur"
        >
          <.focus_wrap
            id="screenshot-viewer-focus"
            phx-mounted={JS.focus_first()}
            class="grid size-full place-items-center p-4 sm:p-8"
          >
            <button
              id="close-screenshot-viewer"
              type="button"
              phx-click="close_screenshot"
              data-dialog-close
              class="absolute right-4 top-4 grid size-11 place-items-center rounded-lg bg-slate-900 text-slate-200 ring-1 ring-slate-700 transition hover:bg-slate-800 hover:text-heading"
              aria-label="Close screenshot viewer"
            >
              <.icon name="hero-x-mark" class="size-6" />
            </button>
            <button
              :if={length(@screenshots) > 1}
              id="previous-screenshot"
              type="button"
              phx-click="previous_screenshot"
              class="absolute left-3 grid size-11 place-items-center rounded-lg bg-slate-900/90 text-heading ring-1 ring-slate-700 transition hover:bg-slate-800 sm:left-6"
              aria-label="Previous screenshot"
            >
              <.icon name="hero-chevron-left" class="size-6" />
            </button>
            <img
              src={screenshot_url(Enum.at(@screenshots, @screenshot_index))}
              alt={"Screenshot #{@screenshot_index + 1} from #{@game.title}"}
              class="max-h-[88vh] max-w-full rounded-xl object-contain shadow-2xl shadow-black"
            />
            <button
              :if={length(@screenshots) > 1}
              id="next-screenshot"
              type="button"
              phx-click="next_screenshot"
              class="absolute right-3 grid size-11 place-items-center rounded-lg bg-slate-900/90 text-heading ring-1 ring-slate-700 transition hover:bg-slate-800 sm:right-6"
              aria-label="Next screenshot"
            >
              <.icon name="hero-chevron-right" class="size-6" />
            </button>
          </.focus_wrap>
        </div>

        <div
          :if={!is_nil(@trailer_index)}
          id="trailer-viewer"
          role="dialog"
          aria-modal="true"
          aria-label={"Trailer for #{@game.title}"}
          phx-window-keydown="close_trailer"
          phx-key="escape"
          phx-remove={JS.pop_focus()}
          class="fixed inset-0 z-50 bg-slate-950/95 backdrop-blur"
        >
          <.focus_wrap
            id="trailer-viewer-focus"
            phx-mounted={JS.focus_first()}
            class="grid size-full place-items-center p-4 sm:p-8"
          >
            <button
              id="close-trailer-viewer"
              type="button"
              phx-click="close_trailer"
              data-dialog-close
              class="absolute right-4 top-4 grid size-11 place-items-center rounded-lg bg-slate-900 text-slate-200 ring-1 ring-slate-700 transition hover:bg-slate-800 hover:text-heading"
              aria-label="Close trailer viewer"
            >
              <.icon name="hero-x-mark" class="size-6" />
            </button>
            <div class="aspect-video w-full max-w-5xl overflow-hidden rounded-2xl bg-black shadow-2xl shadow-black ring-1 ring-slate-700">
              <iframe
                id="trailer-iframe"
                src={video_embed_url(Enum.at(videos(@game), @trailer_index))}
                title={"Trailer for #{@game.title}"}
                class="size-full"
                allow="accelerometer; autoplay; encrypted-media; picture-in-picture"
                allowfullscreen
              ></iframe>
            </div>
          </.focus_wrap>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
