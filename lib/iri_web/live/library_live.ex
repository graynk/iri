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

defmodule IriWeb.LibraryLive do
  @moduledoc "Authenticated paginated library browser with persisted filters and tag search."

  use IriWeb, :live_view

  import IriWeb.LibraryLive.CardPresentation
  import IriWeb.MediaAssetSource, only: [screenshot_url: 1]

  alias Iri.Library
  alias Iri.Media.Policy
  alias IriWeb.LibraryLive.Filters

  @impl true
  def mount(_params, _session, socket) do
    {:ok, filter_options} = Library.list_filter_options(socket.assigns.current_scope)
    {:ok, completion_counts} = Library.completion_state_counts(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "IRI")
     |> assign(:filter_options, filter_options)
     |> assign(:completion_counts, completion_counts)
     |> assign(:filters, empty_filters())
     |> assign(:filters_form, to_form(empty_filters(), as: :filters))
     |> assign(:filters_active?, false)
     |> assign(:filters_open?, false)
     |> assign(:tag_search, "")
     |> assign(:tag_suggestions, [])
     |> assign(:selected_tags, [])
     |> assign(:total_count, 0)
     |> assign(:page, 1)
     |> assign(:page_count, 1)
     |> stream_configure(:games, dom_id: &"source-game-#{&1.id}")
     |> stream(:games, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:ok, page} = Library.list_source_games(socket.assigns.current_scope, params)

    {:ok, selected_tags} =
      Library.list_filter_tags(socket.assigns.current_scope, page.filters["tag_ids"])

    {:noreply,
     socket
     |> assign(:filters, page.filters)
     |> assign(:filters_form, to_form(page.filters, as: :filters))
     |> assign(:filters_active?, filters_active?(page.filters))
     |> assign(:selected_tags, selected_tags)
     |> assign(:total_count, page.total_count)
     |> assign(:page, page.page)
     |> assign(:page_count, page.page_count)
     |> stream(:games, page.entries, reset: true)}
  end

  @impl true
  def handle_event(
        "filter",
        %{"_target" => ["filters", "tag_search"], "filters" => params},
        socket
      ) do
    search = Map.get(params, "tag_search", "")

    {:ok, suggestions} =
      Library.list_tag_suggestions(
        socket.assigns.current_scope,
        search,
        socket.assigns.filters["tag_ids"]
      )

    {:noreply,
     socket
     |> assign(:tag_search, search)
     |> assign(:tag_suggestions, suggestions)}
  end

  def handle_event("filter", %{"filters" => params} = event, socket) do
    params = merge_filter_event(socket.assigns.filters, params, event["_target"])
    {:noreply, push_patch(socket, to: ~p"/library?#{filter_query(params)}")}
  end

  def handle_event("add_tag", %{"id" => id}, socket) do
    tag_ids = Enum.uniq(socket.assigns.filters["tag_ids"] ++ [id])
    params = Map.put(socket.assigns.filters, "tag_ids", tag_ids)

    {:noreply,
     socket
     |> assign(:tag_search, "")
     |> assign(:tag_suggestions, [])
     |> push_patch(to: ~p"/library?#{filter_query(params)}")}
  end

  def handle_event("remove_tag", %{"id" => id}, socket) do
    tag_ids = Enum.reject(socket.assigns.filters["tag_ids"], &(&1 == id))
    params = Map.put(socket.assigns.filters, "tag_ids", tag_ids)

    {:noreply, push_patch(socket, to: ~p"/library?#{filter_query(params)}")}
  end

  def handle_event("toggle_filters", _params, socket) do
    {:noreply, update(socket, :filters_open?, &(!&1))}
  end

  def handle_event("toggle_sort_direction", _params, socket) do
    direction = if socket.assigns.filters["direction"] == "asc", do: "desc", else: "asc"
    params = Map.put(socket.assigns.filters, "direction", direction)
    {:noreply, push_patch(socket, to: ~p"/library?#{filter_query(params)}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="library-page" phx-hook="LibraryHistory" class="mx-auto w-full max-w-7xl space-y-8">
        <header class="space-y-4 border-b border-slate-800 pb-6 sm:space-y-6 sm:pb-7">
          <div class="sm:flex sm:items-start sm:justify-between sm:gap-4">
            <div>
              <h1
                id="library-title"
                tabindex="-1"
                class="text-4xl font-semibold tracking-tight text-heading focus-visible:outline focus-visible:outline-3 focus-visible:outline-offset-4 focus-visible:outline-teal-300"
              >
                Your library
              </h1>
              <div class="mt-2 flex min-h-5 items-center justify-between gap-3">
                <div>
                  <p class="text-sm text-slate-400">
                    {@total_count} {if @total_count == 1, do: "title", else: "titles"} in your library
                  </p>
                  <p id="library-completion-summary" class="mt-1 text-xs text-slate-500" phx-no-format>
                    <span id="library-completed-count"><span class="font-semibold text-emerald-300">{@completion_counts["completed"]}</span> completed</span>
                    <span aria-hidden="true">·</span>
                    <span id="library-dropped-count"><span class="font-semibold text-rose-300">{@completion_counts["dropped"]}</span> dropped</span>
                    <span aria-hidden="true">·</span>
                    <span id="library-playing-count"><span class="font-semibold text-sky-300">{@completion_counts["playing"]}</span> playing</span>
                    <span aria-hidden="true">·</span>
                    <span id="library-backlog-count"><span class="font-semibold text-violet-300">{@completion_counts["backlog"]}</span> want to play</span>
                  </p>
                </div>
                <.link
                  id="clear-library-filters"
                  patch={~p"/library"}
                  aria-hidden={to_string(!@filters_active?)}
                  tabindex={if(@filters_active?, do: "0", else: "-1")}
                  class={[
                    "shrink-0 text-sm font-medium text-teal-300 transition hover:text-teal-200",
                    !@filters_active? && "invisible pointer-events-none"
                  ]}
                >
                  Clear all
                </.link>
              </div>
            </div>
            <.button
              id="add-games-link"
              navigate={~p"/library/add"}
              class="mt-4 gap-2 sm:mt-1"
            ><.icon name="hero-plus" class="size-4" /> Add games</.button>
          </div>

          <.form
            for={@filters_form}
            id="library-search-form"
            phx-change="filter"
            class="w-full"
          >
            <div class="space-y-3 sm:flex sm:items-end sm:gap-3 sm:space-y-0">
              <div id="library-search-control" class="w-full min-w-0 sm:flex-1">
                <.search_input
                  field={@filters_form[:q]}
                  id="library-search"
                  label="Search"
                  placeholder="Search titles and descriptions…"
                  autocomplete="off"
                  phx-debounce="250"
                />
              </div>
              <div
                id="library-toolbar-actions"
                class="grid w-full grid-cols-2 items-end gap-3 sm:w-auto sm:shrink-0 sm:grid-cols-[12rem_auto]"
              >
                <div class="min-w-0">
                  <.sort_input
                    field={@filters_form[:sort]}
                    id="library-sort"
                    label="Sort by"
                    direction={@filters["direction"]}
                    options={[
                      {"Title", "title"},
                      {"Metadata rating", "rating"},
                      {"My rating", "my_rating"},
                      {"Playtime", "playtime"},
                      {"Year of release", "release_year"}
                    ]}
                  />
                </div>
                <button
                  id="toggle-library-filters"
                  type="button"
                  phx-click="toggle_filters"
                  aria-expanded={to_string(@filters_open?)}
                  aria-controls="library-filter-panel"
                  class={[
                    "inline-flex min-h-11 w-full min-w-0 items-center justify-center gap-2 rounded-xl border px-3 text-sm font-semibold transition sm:w-auto",
                    @filters_active? && "border-teal-400/40 bg-teal-400/10 text-teal-200",
                    !@filters_active? && "border-slate-700 text-slate-300 hover:bg-slate-800"
                  ]}
                >
                  <.icon name="hero-adjustments-horizontal" class="size-4" /> Filters
                  <span
                    :if={active_filter_count(@filters) > 0}
                    class="rounded-full bg-teal-300/15 px-1.5 py-0.5 text-[0.65rem] text-teal-100"
                  >
                    {active_filter_count(@filters)}
                  </span>
                  <.icon
                    name={if(@filters_open?, do: "hero-chevron-up", else: "hero-chevron-down")}
                    class="size-3.5"
                  />
                </button>
              </div>
            </div>

            <div
              id="library-filter-panel"
              class={[
                "mt-3 items-start gap-3 rounded-2xl border border-slate-800 bg-slate-900/45 p-3 sm:p-4 lg:grid-cols-3 xl:grid-cols-5",
                @filters_open? && "grid grid-cols-1 sm:grid-cols-2",
                !@filters_open? && "hidden"
              ]}
            >
              <.filter_group
                id="library-filter-libraries"
                name="account_ids"
                label="Libraries"
                options={account_options(@filter_options.accounts, @current_scope.user.id)}
                selected={@filters["account_ids"]}
              />
              <.filter_group
                id="library-filter-stores"
                name="providers"
                label="Stores"
                options={[
                  {"Steam", "steam"},
                  {"GOG", "gog"},
                  {"Epic Games", "epic"},
                  {"PlayStation", "psn"},
                  {"Xbox", "xbox"},
                  {"Custom", "igdb"}
                ]}
                selected={@filters["providers"]}
              />
              <.filter_group
                id="library-filter-platforms"
                name="platforms"
                label="Platforms"
                options={[{"Windows", "windows"}, {"macOS", "mac"}, {"Linux", "linux"}]}
                selected={@filters["platforms"]}
              />
              <.filter_group
                id="library-filter-genres"
                name="genre_ids"
                label="Genres"
                options={term_options(@filter_options.genres)}
                selected={@filters["genre_ids"]}
              />
              <.filter_group
                id="library-filter-modes"
                name="game_modes"
                label="Game modes"
                options={[{"Virtual reality", "vr"} | term_options(@filter_options.game_modes)]}
                selected={@filters["game_modes"]}
              />
              <.filter_group
                id="library-filter-statuses"
                name="states"
                label="Completion status"
                options={[
                  {"Playing", "playing"},
                  {"Want to play", "backlog"},
                  {"Completed", "completed"},
                  {"Dropped", "dropped"},
                  {"Not played", "not_played"}
                ]}
                selected={@filters["states"]}
              />
              <.filter_group
                id="library-filter-controllers"
                name="controllers"
                label="Controller"
                options={[{"Full support", "full"}, {"Partial support", "partial"}]}
                selected={@filters["controllers"]}
              />
              <.filter_group
                id="library-filter-deck"
                name="deck"
                label="Steam Deck"
                options={[{"Ideal", "ideal"}, {"Playable", "playable"}]}
                selected={@filters["deck"]}
              />
              <.filter_group
                id="library-filter-themes"
                name="theme_ids"
                label="Themes"
                options={term_options(@filter_options.themes)}
                selected={@filters["theme_ids"]}
              />
              <div
                id="library-filter-tags"
                class="relative rounded-xl border border-slate-800 bg-slate-950/55 p-3"
              >
                <.search_input
                  id="library-tag-search"
                  name="filters[tag_search]"
                  value={@tag_search}
                  label="Tags"
                  placeholder="Search tags…"
                  autocomplete="off"
                  phx-debounce="250"
                  class="min-h-10 w-full rounded-lg border border-slate-700 bg-slate-900 px-3 py-2 text-base text-slate-100 outline-none transition placeholder:text-slate-600 focus:border-teal-300 focus:ring-2 focus:ring-teal-300/20 sm:text-sm"
                />
                <div
                  :if={@selected_tags != []}
                  id="selected-tag-filters"
                  class="mt-3 flex flex-wrap gap-1.5"
                >
                  <span :for={tag <- @selected_tags} class="inline-flex">
                    <input type="hidden" name="filters[tag_ids][]" value={tag.id} />
                    <button
                      id={"remove-tag-#{tag.id}"}
                      type="button"
                      phx-click="remove_tag"
                      phx-value-id={tag.id}
                      class="inline-flex items-center gap-1.5 rounded-full bg-teal-400/12 px-2.5 py-1.5 text-xs font-medium text-teal-100 ring-1 ring-teal-400/25 transition hover:bg-teal-400/20"
                      aria-label={"Remove #{tag.name} tag filter"}
                    >
                      {tag.name} <.icon name="hero-x-mark" class="size-3.5" />
                    </button>
                  </span>
                </div>
                <div
                  :if={@tag_suggestions != []}
                  id="tag-suggestions"
                  class="absolute inset-x-3 top-[4.7rem] z-30 overflow-hidden rounded-xl border border-slate-700 bg-slate-900 shadow-2xl shadow-black/40"
                >
                  <button
                    :for={tag <- @tag_suggestions}
                    id={"add-tag-#{tag.id}"}
                    type="button"
                    phx-click="add_tag"
                    phx-value-id={tag.id}
                    class="flex w-full items-center justify-between gap-3 border-b border-slate-800 px-3 py-2.5 text-left text-sm text-slate-300 transition last:border-0 hover:bg-slate-800 hover:text-heading"
                  >
                    <span class="truncate">{tag.name}</span>
                    <.icon name="hero-plus" class="size-4 shrink-0 text-teal-300" />
                  </button>
                </div>
                <p class="mt-2 text-[0.68rem] leading-4 text-slate-600">
                  Search, then add one or more tags.
                </p>
              </div>
            </div>
          </.form>
        </header>

        <div
          id="library-games"
          phx-update="stream"
          class="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-6"
        >
          <div
            id="library-games-empty"
            class="col-span-full hidden rounded-3xl border border-dashed border-slate-700 px-6 py-16 text-center only:block"
          >
            <.icon name="hero-squares-2x2" class="mx-auto size-8 text-slate-600" />
            <p class="mt-4 font-medium text-slate-200">No local games found</p>
            <p class="mt-1 text-sm text-slate-500">
              <.link
                navigate={~p"/settings/integrations"}
                class="font-semibold text-teal-300 underline decoration-teal-400/50 underline-offset-4 transition hover:text-teal-200"
              >
                Connect and sync a Steam or GOG account
              </.link>
              , or adjust the active filters.
            </p>
          </div>

          <article
            :for={{id, source} <- @streams.games}
            id={id}
            phx-hook=".CardPreview"
            data-gamepad-card
            data-gamepad-selected="false"
            class="group relative flex h-full min-w-0 flex-col overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/60 transition-colors duration-150 hover:border-teal-300 hover:ring-1 hover:ring-teal-300 focus-within:border-teal-300 focus-within:ring-1 focus-within:ring-teal-300"
          >
            <.game_card
              source={source}
              current_user={@current_scope.user}
              game_path={source.game && ~p"/games/#{source.game.slug}"}
            />
          </article>
        </div>

        <p
          id="library-page-status"
          role="status"
          aria-live="polite"
          aria-atomic="true"
          class="sr-only"
        >
          Library page {@page} of {@page_count}
        </p>

        <nav
          :if={@page_count > 1}
          id="library-pagination"
          aria-label="Library pages"
          class="flex flex-wrap items-center justify-center gap-2 pt-2"
        >
          <.link
            :if={@page > 1}
            id="library-previous-page"
            patch={~p"/library?#{filter_query(@filters, @page - 1)}"}
            data-library-page-link
            class="inline-flex min-h-11 items-center gap-1.5 rounded-xl border border-slate-700 px-3 py-2 text-sm font-semibold text-slate-300 transition hover:bg-slate-800 hover:text-heading"
          >
            <.icon name="hero-chevron-left" class="size-4" /> Previous
          </.link>

          <div class="flex items-center gap-1">
            <%= for token <- pagination_tokens(@page, @page_count) do %>
              <span :if={token == :ellipsis} class="px-1 text-sm text-slate-600" aria-hidden="true">…</span>
              <.link
                :if={is_integer(token)}
                id={"library-page-#{token}"}
                patch={~p"/library?#{filter_query(@filters, token)}"}
                data-library-page-link
                aria-label={"Page #{token}"}
                aria-current={if(token == @page, do: "page")}
                class={[
                  "grid size-10 place-items-center rounded-xl text-sm font-semibold transition",
                  token == @page && "bg-teal-300 text-on-accent",
                  token != @page && "text-slate-400 hover:bg-slate-800 hover:text-heading"
                ]}
              >
                {token}
              </.link>
            <% end %>
          </div>

          <.link
            :if={@page < @page_count}
            id="library-next-page"
            patch={~p"/library?#{filter_query(@filters, @page + 1)}"}
            data-library-page-link
            class="inline-flex min-h-11 items-center gap-1.5 rounded-xl border border-slate-700 px-3 py-2 text-sm font-semibold text-slate-300 transition hover:bg-slate-800 hover:text-heading"
          >
            Next <.icon name="hero-chevron-right" class="size-4" />
          </.link>
        </nav>

        <footer
          id="library-footer"
          class="border-t border-slate-800/70 pt-5 text-center text-xs text-slate-500"
        >
          <a
            id="iri-source-link"
            href="https://github.com/graynk/iri"
            target="_blank"
            rel="noopener noreferrer"
            class="font-medium text-slate-400 transition hover:text-teal-300"
          >
            Source code
          </a>
        </footer>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".CardPreview">
          export default {
            mounted() {
              this.frames = Array.from(this.el.querySelectorAll("[data-card-preview-frame]"))
                .map(frame => frame.dataset.src)
              this.cover = this.el.querySelector("[data-card-preview-cover]")
              this.layer = this.el.querySelector("[data-card-preview-layer]")
              this.image = this.el.querySelector("[data-card-preview-image]")
              this.backdrop = this.el.querySelector("[data-card-preview-backdrop]")
              this.preloads = new Map()
              this.index = 0
              this.timer = null
              this.activationTimer = null
              this.panFrames = []
              this.active = false
              this.touchOrigin = null
              this.touchActivated = false
              this.motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)")
              this.reducedMotion = this.motionQuery.matches

              this.syncMotionPreference = event => {
                this.reducedMotion = event.matches

                if (this.reducedMotion) {
                  this.stopTimer()
                  this.cancelPan()
                  if (this.image) {
                    this.image.style.transition = "none"
                    this.image.style.transform = "none"
                  }
                }
              }

              this.activate = () => {
                this.stopActivationTimer()
                if (this.frames.length === 0) return

                window.dispatchEvent(new CustomEvent("iri:card-preview-start", {
                  detail: {id: this.el.id}
                }))
                this.stopTimer()
                this.active = true
                this.show(0)
              }

              this.queueActivation = event => {
                if (event.pointerType === "touch") return
                this.stopActivationTimer()
                this.activationTimer = window.setTimeout(this.activate, 180)
              }

              this.trackTouchStart = event => {
                const touch = event.touches[0]
                if (!touch) return

                this.touchOrigin = {x: touch.clientX, y: touch.clientY}
                this.touchActivated = false
              }

              this.trackTouchMove = event => {
                const touch = event.touches[0]
                if (!touch || !this.touchOrigin || this.touchActivated) return

                const horizontal = Math.abs(touch.clientX - this.touchOrigin.x)
                const vertical = Math.abs(touch.clientY - this.touchOrigin.y)

                if (Math.max(horizontal, vertical) >= 12) {
                  this.touchActivated = true
                  this.activate()
                }
              }

              this.clearTouch = () => {
                this.touchOrigin = null
                this.touchActivated = false
              }

              this.stopOtherPreview = event => {
                if (event.detail.id !== this.el.id) this.stop()
              }

              this.stop = () => {
                this.stopActivationTimer()
                this.stopTimer()
                this.cancelPan()
                this.active = false
                this.layer?.classList.remove("opacity-100")
                this.cover?.classList.remove("opacity-0")
              }

              this.stopOnOutsideTouch = event => {
                if (!this.el.contains(event.target)) this.stop()
              }

              this.el.addEventListener("pointerenter", this.queueActivation)
              this.el.addEventListener("pointerleave", this.stop)
              this.el.addEventListener("touchstart", this.trackTouchStart, {passive: true})
              this.el.addEventListener("touchmove", this.trackTouchMove, {passive: true})
              this.el.addEventListener("touchend", this.clearTouch, {passive: true})
              this.el.addEventListener("touchcancel", this.clearTouch, {passive: true})
              document.addEventListener("pointerdown", this.stopOnOutsideTouch, {passive: true})
              window.addEventListener("iri:card-preview-start", this.stopOtherPreview)
              this.motionQuery.addEventListener("change", this.syncMotionPreference)

              this.observer = new IntersectionObserver(entries => {
                if (entries[0].isIntersecting) this.preload(0)
                else this.stop()
              }, {rootMargin: "160px"})
              this.observer.observe(this.el)
            },

            show(index) {
              this.index = index
              const url = this.frames[index]

              this.preload(index).then(loaded => {
                if (!this.active || this.index !== index) return

                if (loaded) {
                  this.image.src = url
                  this.backdrop.src = url
                  this.layer?.classList.add("opacity-100")
                  this.cover?.classList.add("opacity-0")

                  if (this.reducedMotion) {
                    this.cancelPan()
                    this.image.style.transition = "none"
                    this.image.style.transform = "none"
                  } else {
                    this.preload((index + 1) % this.frames.length)
                    this.panScreenshot(index)
                  }
                }

                this.scheduleNext()
              })
            },

            scheduleNext() {
              this.stopTimer()
              if (!this.active || this.reducedMotion || this.frames.length < 2) return

              this.timer = window.setTimeout(() => {
                this.show((this.index + 1) % this.frames.length)
              }, 2250)
            },

            panScreenshot(index) {
              this.cancelPan()
              const paths = [
                [[0, 0], [-9, -9]],
                [[-9, 0], [0, -9]],
                [[0, -9], [-9, 0]],
                [[-9, -9], [0, 0]]
              ]
              const [start, finish] = paths[index % paths.length]

              this.image.style.transition = "none"
              this.image.style.transform = `translate3d(${start[0]}%, ${start[1]}%, 0) scale(1.32)`

              const startFrame = window.requestAnimationFrame(() => {
                const animateFrame = window.requestAnimationFrame(() => {
                  this.image.style.transition = "transform 2350ms linear"
                  this.image.style.transform = `translate3d(${finish[0]}%, ${finish[1]}%, 0) scale(1.32)`
                })
                this.panFrames.push(animateFrame)
              })
              this.panFrames.push(startFrame)
            },

            cancelPan() {
              this.panFrames.forEach(frame => window.cancelAnimationFrame(frame))
              this.panFrames = []
            },

            preload(index) {
              const url = this.frames[index]
              if (!url) return Promise.resolve(false)
              if (this.preloads.has(url)) return this.preloads.get(url)

              const pending = new Promise(resolve => {
                const image = new Image()
                image.onload = () => resolve(true)
                image.onerror = () => resolve(false)
                image.src = url
              })

              this.preloads.set(url, pending)
              return pending
            },

            stopTimer() {
              if (this.timer) window.clearTimeout(this.timer)
              this.timer = null
            },

            stopActivationTimer() {
              if (this.activationTimer) window.clearTimeout(this.activationTimer)
              this.activationTimer = null
            },

            destroyed() {
              this.stopActivationTimer()
              this.stopTimer()
              this.cancelPan()
              this.observer?.disconnect()
              this.el.removeEventListener("pointerenter", this.queueActivation)
              this.el.removeEventListener("pointerleave", this.stop)
              this.el.removeEventListener("touchstart", this.trackTouchStart)
              this.el.removeEventListener("touchmove", this.trackTouchMove)
              this.el.removeEventListener("touchend", this.clearTouch)
              this.el.removeEventListener("touchcancel", this.clearTouch)
              document.removeEventListener("pointerdown", this.stopOnOutsideTouch)
              window.removeEventListener("iri:card-preview-start", this.stopOtherPreview)
              this.motionQuery.removeEventListener("change", this.syncMotionPreference)
            }
          }
        </script>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".PersistentFilterGroup">
          export default {
            beforeUpdate() {
              this.keepOpen = this.el.open
            },

            updated() {
              if (this.keepOpen) this.el.open = true
            }
          }
        </script>
      </div>
    </Layouts.app>
    """
  end

  defp empty_filters, do: Filters.defaults()
  defp filter_query(params, page \\ 1), do: Filters.query(params, page)
  defp pagination_tokens(page, page_count), do: Filters.pagination_tokens(page, page_count)

  defp merge_filter_event(current, incoming, target),
    do: Filters.merge_event(current, incoming, target)

  defp filters_active?(filters), do: Filters.active?(filters)
  defp active_filter_count(filters), do: Filters.active_count(filters)
  defp account_options(accounts, user_id), do: Filters.account_options(accounts, user_id)
  defp term_options(terms), do: Filters.term_options(terms)

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :selected, :list, required: true

  defp filter_group(assigns) do
    ~H"""
    <details
      id={@id}
      phx-hook=".PersistentFilterGroup"
      open={@selected != []}
      class="group min-w-0 overflow-hidden rounded-xl border border-slate-800 bg-slate-950/55 open:bg-slate-950/80"
    >
      <summary class="flex min-h-11 cursor-pointer list-none items-center justify-between gap-2 px-3 text-sm font-medium text-slate-200 transition hover:bg-slate-800/70 [&::-webkit-details-marker]:hidden">
        <span>{@label}</span>
        <span class="flex items-center gap-2">
          <span
            :if={@selected != []}
            class="rounded-full bg-teal-400/15 px-2 py-0.5 text-[0.65rem] font-bold text-teal-200"
          >
            {length(@selected)}
          </span>
          <.icon
            name="hero-chevron-down"
            class="size-3.5 text-slate-500 transition group-open:rotate-180"
          />
        </span>
      </summary>
      <div class="max-h-44 space-y-1 overflow-y-auto border-t border-slate-800 p-2">
        <p :if={@options == []} class="px-2 py-1.5 text-xs text-slate-600">No options yet</p>
        <label
          :for={{label, value} <- @options}
          for={"#{@id}-#{value}"}
          class="flex cursor-pointer items-start gap-2 rounded-lg px-2 py-1.5 text-xs text-slate-400 transition hover:bg-slate-800 hover:text-slate-200"
        >
          <input
            type="checkbox"
            id={"#{@id}-#{value}"}
            name={"filters[#{@name}][]"}
            value={value}
            checked={value in @selected}
            class="mt-0.5 size-3.5 shrink-0 rounded border-slate-600 bg-slate-900 text-teal-300 focus:ring-teal-300"
          />
          <span class="leading-4">{label}</span>
        </label>
      </div>
    </details>
    """
  end

  attr :source, :map, required: true
  attr :current_user, :map, required: true
  attr :game_path, :string, default: nil

  defp game_card(assigns) do
    media_subject = assigns.source.game || assigns.source

    assigns =
      assigns
      |> assign(:media_subject, media_subject)
      |> assign(
        :cover,
        if(Policy.hidden?(media_subject, assigns.current_user),
          do: nil,
          else: cover_asset(assigns.source)
        )
      )
      |> assign(
        :preview_screenshots,
        if(Policy.restricted?(media_subject, assigns.current_user),
          do: [],
          else: preview_screenshots(assigns.source)
        )
      )

    ~H"""
    <div
      id={"card-preview-#{@source.id}"}
      data-sensitive-carousel={if(@preview_screenshots == [], do: "disabled", else: "enabled")}
      class={[
        "relative aspect-[3/4] overflow-hidden bg-gradient-to-br",
        fallback_gradient(@source.id)
      ]}
    >
      <img
        :if={@cover}
        data-card-preview-cover
        src={~p"/media/#{@cover.id}"}
        alt=""
        loading="lazy"
        data-sensitive-media={if(Policy.blurred?(@media_subject, @current_user), do: "blurred")}
        class={[
          "absolute inset-0 size-full object-cover transition duration-100",
          Policy.image_class(@media_subject, @current_user)
        ]}
      />
      <div
        :if={!@cover}
        data-card-preview-cover
        class="absolute inset-0 bg-slate-900 transition-opacity duration-100"
      />
      <span
        :if={!@cover}
        class="absolute inset-0 grid place-items-center text-5xl font-semibold text-slate-600 transition-opacity duration-100"
      >
        {display_title(@source) |> String.first() |> String.upcase()}
      </span>
      <span
        :if={Policy.restricted?(@media_subject, @current_user)}
        class="pointer-events-none absolute inset-x-3 bottom-3 z-20 rounded-lg bg-slate-950/80 px-2 py-1 text-center text-[11px] font-semibold text-slate-200 backdrop-blur"
      >
        Sensitive media {if Policy.hidden?(@media_subject, @current_user),
          do: "hidden",
          else: "blurred"}
      </span>

      <span
        :for={asset <- @preview_screenshots}
        data-card-preview-frame
        data-src={screenshot_url(asset)}
        class="hidden"
      ></span>
      <div
        :if={@preview_screenshots != []}
        data-card-preview-layer
        class="pointer-events-none absolute inset-0 z-10 opacity-0 transition-opacity duration-100"
      >
        <img
          data-card-preview-backdrop
          src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
          alt=""
          aria-hidden="true"
          class="absolute inset-0 size-full scale-110 object-cover opacity-50 blur-xl"
        />
        <div class="absolute inset-0 bg-slate-950/25"></div>
        <img
          data-card-preview-image
          src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
          alt=""
          aria-hidden="true"
          class="absolute inset-0 size-full origin-top-left object-cover will-change-transform"
        />
      </div>

      <div class="absolute left-3 top-3 z-20 flex max-w-[calc(100%-1.5rem)] flex-col items-start gap-2">
        <div class="flex flex-wrap gap-1.5">
          <span :for={provider <- source_providers(@source)} class={provider_badge(provider)}>
            {provider}
          </span>
        </div>
        <span
          :if={personal_state(@source)}
          class={state_badge(personal_state(@source))}
        >
          {state_label(personal_state(@source))}
        </span>
      </div>
    </div>

    <div class="flex flex-1 flex-col p-3.5">
      <div class="space-y-3">
        <div class="flex min-h-10 items-start gap-2">
          <h2
            id={"game-card-title-#{@source.id}"}
            class="line-clamp-2 min-w-0 flex-1 break-words text-sm font-semibold leading-5 text-slate-100"
          >
            <.link
              :if={@game_path}
              navigate={@game_path}
              data-library-game-link
              data-gamepad-item
              class="touch-manipulation after:absolute after:inset-0 after:z-10 after:content-[''] focus:outline-none"
            >
              {display_title(@source)}
            </.link>
            <span :if={!@game_path}>{display_title(@source)}</span>
          </h2>
          <span class="flex shrink-0 items-center gap-1">
            <span
              :if={personal_rating(@source)}
              class={personal_rating_badge(personal_rating(@source))}
              role="img"
              aria-label={
                "My rating: #{format_rating_value(personal_rating(@source))} out of 5 — #{rating_label(personal_rating(@source))}"
              }
              title={
                "My rating: #{format_rating_value(personal_rating(@source))} out of 5 — #{rating_label(personal_rating(@source))}"
              }
            >
              <.rating_face rating={personal_rating(@source)} class="size-4" />
            </span>
            <span
              :if={source_rating(@source)}
              class={rating_badge(source_rating(@source))}
              role="img"
              aria-label={"Metadata rating: #{round(source_rating(@source))}%"}
            >
              <.icon name="hero-hand-thumb-up" class="size-3" />
              {round(source_rating(@source))}%
            </span>
          </span>
        </div>
        <p
          :if={summary(@source)}
          class="line-clamp-2 min-h-9 text-xs leading-[1.125rem] text-slate-400"
        >
          {summary(@source)}
        </p>
        <p
          :if={prominent_terms(@source) != []}
          class="min-h-5 truncate text-[0.68rem] leading-5 text-slate-500"
        >
          {Enum.map_join(prominent_terms(@source), " · ", & &1.name)}
        </p>
        <div :if={compatibility_badges(@source) != []} class="flex min-h-5 flex-wrap gap-1">
          <span
            :for={{label, classes} <- compatibility_badges(@source)}
            class={["rounded-md px-1.5 py-0.5 text-[0.65rem] font-medium", classes]}
          >
            {label}
          </span>
        </div>
      </div>
      <div
        id={"card-footer-#{@source.id}"}
        class="mt-auto flex items-center justify-between gap-2 pt-4 text-xs text-slate-500"
      >
        <span class="truncate">{owner_names(@source)}</span>
        <span :if={playtime_label(@source, @current_user)} class="shrink-0">
          {playtime_label(@source, @current_user)}
        </span>
      </div>
    </div>
    """
  end
end
