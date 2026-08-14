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

defmodule IriWeb.CompanyLive do
  @moduledoc "Authenticated company page limited to canonical games visible in the viewer's library."

  use IriWeb, :live_view

  import IriWeb.LibraryLive.CardPresentation,
    only: [
      cover_asset: 1,
      fallback_gradient: 1,
      personal_state: 1,
      prominent_terms: 1,
      provider_badge: 1,
      source_providers: 1,
      state_badge: 1,
      state_label: 1,
      summary: 1
    ]

  alias Iri.Library.Companies
  alias Iri.Media.Policy

  @impl true
  def mount(%{"id" => company_id}, _session, socket) do
    case Companies.get_in_library(socket.assigns.current_scope, company_id) do
      {:ok, %{company: company, games: games, total_count: total_count}} ->
        entries = Enum.map(games, &%{id: &1.id, game: &1})

        {:ok,
         socket
         |> assign(:page_title, company.name)
         |> assign(:company, company)
         |> assign(:company_roles, company_roles(games))
         |> assign(:total_count, total_count)
         |> stream_configure(:company_games, dom_id: &"company-game-#{&1.id}")
         |> stream(:company_games, entries)}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "That company has no games in your accessible libraries.")
         |> push_navigate(to: ~p"/library")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="company-page" class="mx-auto w-full max-w-7xl">
        <header class="border-b border-slate-800 pb-7">
          <.link
            id="company-back-to-library"
            navigate={~p"/library"}
            phx-hook="LibraryLink"
            class="inline-flex min-h-10 items-center gap-2 text-sm text-slate-400 transition hover:text-heading"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to library
          </.link>

          <div class="mt-5 flex flex-wrap items-end justify-between gap-5">
            <div class="min-w-0">
              <p
                id="company-roles"
                class="text-xs font-semibold uppercase tracking-[0.24em] text-teal-300"
              >
                {role_summary(@company_roles)}
              </p>
              <h1
                id="company-name"
                class="mt-2 break-words text-4xl font-semibold tracking-tight text-heading sm:text-5xl"
              >
                {@company.name}
              </h1>
              <p id="company-game-count" class="mt-3 text-sm text-slate-400">
                {@total_count} {pluralize(@total_count, "game", "games")} across your connected and shared libraries
              </p>
            </div>

            <div class="hidden rounded-2xl border border-teal-400/20 bg-teal-400/5 p-3 text-teal-200 sm:block">
              <.icon name="hero-building-office-2" class="size-7" />
            </div>
          </div>
        </header>

        <section class="pt-7" aria-labelledby="company-library-heading">
          <h2 id="company-library-heading" class="sr-only">Games in your libraries</h2>
          <div
            id="company-games"
            phx-update="stream"
            class="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5"
          >
            <.company_game_card
              :for={{id, entry} <- @streams.company_games}
              id={id}
              entry={entry}
              current_user={@current_scope.user}
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :current_user, :map, required: true

  defp company_game_card(assigns) do
    media_subject = assigns.entry.game

    assigns =
      assigns
      |> assign(:media_subject, media_subject)
      |> assign(:personal_state, personal_state(assigns.entry))
      |> assign(
        :cover,
        if(Policy.hidden?(media_subject, assigns.current_user),
          do: nil,
          else: cover_asset(assigns.entry)
        )
      )

    ~H"""
    <article
      id={@id}
      class="group min-w-0 overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/45 shadow-lg shadow-black/10 transition duration-200 hover:-translate-y-0.5 hover:border-slate-700 hover:bg-slate-900/75 hover:shadow-xl hover:shadow-black/20"
    >
      <.link
        id={"company-game-link-#{@entry.game.id}"}
        navigate={~p"/games/#{@entry.game.slug}"}
        class="flex h-full flex-col focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-teal-300"
      >
        <div class={[
          "relative aspect-[3/4] overflow-hidden bg-gradient-to-br",
          fallback_gradient(@entry.game.id)
        ]}>
          <img
            :if={@cover}
            src={~p"/media/#{@cover.id}"}
            alt=""
            loading="lazy"
            data-sensitive-media={if(Policy.blurred?(@media_subject, @current_user), do: "blurred")}
            class={[
              "absolute inset-0 size-full object-cover transition duration-300 group-hover:scale-[1.025]",
              Policy.image_class(@media_subject, @current_user)
            ]}
          />
          <div
            :if={!@cover}
            class="absolute inset-0 bg-[radial-gradient(circle_at_30%_20%,rgba(255,255,255,0.18),transparent_35%)]"
          >
          </div>
          <span
            :if={!@cover}
            class="absolute inset-0 grid place-items-center text-5xl font-black text-white/65"
          >
            {String.first(@entry.game.title)}
          </span>

          <div class="absolute left-3 top-3 flex max-w-[calc(100%-1.5rem)] flex-wrap gap-1.5">
            <span
              :for={provider <- source_providers(@entry)}
              class={provider_badge(provider)}
            >
              {provider}
            </span>
          </div>

          <span
            :if={@personal_state && !Policy.restricted?(@media_subject, @current_user)}
            class={[state_badge(@personal_state), "absolute bottom-3 left-3"]}
          >
            {state_label(@personal_state)}
          </span>

          <span
            :if={Policy.restricted?(@media_subject, @current_user)}
            class="absolute inset-x-3 bottom-3 rounded-lg bg-slate-950/80 px-2 py-1 text-center text-[11px] font-semibold text-slate-200 backdrop-blur"
          >
            Sensitive media {if Policy.hidden?(@media_subject, @current_user),
              do: "hidden",
              else: "blurred"}
          </span>
        </div>

        <div class="flex flex-1 flex-col p-3.5">
          <div class="flex flex-wrap gap-1.5">
            <span
              :for={role <- game_roles(@entry.game)}
              class="rounded-md bg-teal-400/10 px-1.5 py-0.5 text-[0.65rem] font-bold uppercase tracking-wider text-teal-200"
            >
              {role}
            </span>
          </div>
          <h3 class="mt-2 line-clamp-2 text-sm font-semibold leading-5 text-slate-100 transition group-hover:text-heading">
            {@entry.game.title}
          </h3>
          <p class="mt-1 text-xs text-slate-500">{release_label(@entry.game)}</p>
          <p
            :if={summary(@entry)}
            class="mt-3 line-clamp-2 text-xs leading-[1.125rem] text-slate-400"
          >
            {summary(@entry)}
          </p>
          <div class="mt-auto flex flex-wrap gap-1.5 pt-3">
            <span
              :for={term <- prominent_terms(@entry)}
              class="rounded-md bg-slate-800 px-1.5 py-1 text-[0.65rem] text-slate-400"
            >
              {term.name}
            </span>
          </div>
        </div>
      </.link>
    </article>
    """
  end

  defp company_roles(games) do
    games
    |> Enum.flat_map(& &1.game_companies)
    |> Enum.map(& &1.role)
    |> Enum.uniq()
    |> Enum.sort_by(&role_order/1)
  end

  defp game_roles(game) do
    game.game_companies
    |> Enum.map(& &1.role)
    |> Enum.uniq()
    |> Enum.sort_by(&role_order/1)
    |> Enum.map(&role_label/1)
  end

  defp role_summary(roles), do: roles |> Enum.map_join(" & ", &role_label/1)

  defp role_label("developer"), do: "Developer"
  defp role_label("publisher"), do: "Publisher"
  defp role_label(role), do: String.capitalize(role)

  defp role_order("developer"), do: {0, "developer"}
  defp role_order("publisher"), do: {1, "publisher"}
  defp role_order(role), do: {2, role}

  defp release_label(%{release_year: year}) when is_integer(year), do: Integer.to_string(year)
  defp release_label(_game), do: "Release year unknown"

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural
end
