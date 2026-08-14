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

defmodule IriWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use IriWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :jump_to_top, :boolean, default: true

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a
      href="#main-content"
      class="sr-only z-50 rounded-lg bg-teal-300 px-4 py-2 text-sm font-semibold text-on-accent focus:not-sr-only focus:fixed focus:left-4 focus:top-4"
    >
      Skip to main content
    </a>
    <header class="sticky top-0 z-40 border-b border-slate-800/80 bg-slate-950/85 px-3 backdrop-blur-xl sm:px-6 lg:px-8">
      <div class="mx-auto flex h-16 max-w-7xl items-center justify-between">
        <.link
          id="iri-home-link"
          navigate={~p"/library"}
          phx-hook="LibraryLink"
          aria-label="IRI library"
          class="flex shrink-0 items-center text-heading transition hover:text-teal-200 sm:gap-3"
        >
          <img
            src={~p"/images/iri-icon.svg"}
            alt=""
            class="size-10 rounded-lg"
          />
          <span class="hidden font-semibold tracking-tight sm:inline">IRI</span>
        </.link>
        <nav aria-label="Main" class="flex shrink-0 items-center gap-1 text-sm sm:gap-2">
          <div
            id="theme-switcher"
            phx-hook="ThemeSwitcher"
            data-theme-cookie={IriWeb.Theme.cookie_name()}
            class="relative"
          >
            <button
              type="button"
              data-theme-toggle
              aria-controls="theme-options"
              aria-expanded="false"
              aria-label="Theme"
              title="Theme"
              class="inline-flex size-11 cursor-pointer items-center justify-center gap-1.5 whitespace-nowrap rounded-lg border border-slate-700/80 bg-slate-900/30 text-slate-300 transition hover:border-teal-400/50 hover:bg-teal-400/10 hover:text-teal-100 sm:w-auto sm:px-3"
            >
              <.icon name="hero-swatch" class="size-4" />
              <span class="hidden sm:inline">Theme</span>
            </button>
            <div
              id="theme-options"
              data-theme-menu
              role="group"
              aria-label="Choose a theme"
              hidden
              class="absolute right-0 top-full z-50 mt-2 w-40 rounded-lg border border-slate-700 bg-slate-900 p-1 shadow-xl shadow-black/30"
            >
              <button
                :for={theme <- IriWeb.Theme.options()}
                type="button"
                aria-pressed="false"
                data-theme-option={theme.value}
                data-theme-color={theme.color}
                class="group flex w-full cursor-pointer items-center justify-between gap-2 rounded-md px-3 py-2 text-left text-sm text-slate-300 transition hover:bg-slate-800 hover:text-heading aria-pressed:font-semibold aria-pressed:text-teal-300"
              >
                {theme.label}
                <.icon name="hero-check" class="invisible size-4 group-aria-pressed:visible" />
              </button>
            </div>
          </div>
          <.link
            :if={@current_scope}
            id="collections-nav-link"
            navigate={~p"/collections"}
            aria-label="Collections"
            title="Collections"
            class="inline-flex size-11 items-center justify-center gap-1.5 whitespace-nowrap rounded-lg border border-slate-700/80 bg-slate-900/30 text-slate-300 transition hover:border-teal-400/50 hover:bg-teal-400/10 hover:text-teal-100 sm:w-auto sm:px-3"
          >
            <.icon name="hero-bookmark-square" class="size-4" />
            <span class="hidden sm:inline">Collections</span>
          </.link>
          <.link
            :if={@current_scope}
            id="bulk-edit-nav-link"
            navigate={~p"/library/statuses"}
            aria-label="Bulk edit"
            title="Bulk edit"
            class="inline-flex size-11 items-center justify-center gap-1.5 whitespace-nowrap rounded-lg border border-slate-700/80 bg-slate-900/30 text-slate-300 transition hover:border-teal-400/50 hover:bg-teal-400/10 hover:text-teal-100 sm:w-auto sm:px-3"
          >
            <.icon name="hero-pencil-square" class="size-4" />
            <span class="hidden sm:inline">Bulk edit</span>
          </.link>
          <.link
            :if={@current_scope}
            id="settings-nav-link"
            navigate={~p"/settings/account"}
            aria-label="Settings"
            title="Settings"
            class="inline-flex size-11 items-center justify-center gap-1.5 rounded-lg border border-slate-700/80 bg-slate-900/30 text-slate-300 transition hover:border-teal-400/50 hover:bg-teal-400/10 hover:text-teal-100 sm:w-auto sm:px-3"
          >
            <.icon name="hero-cog-6-tooth" class="size-4" />
            <span class="hidden sm:inline">Settings</span>
          </.link>
          <.link
            :if={@current_scope}
            href={~p"/users/log-out"}
            method="delete"
            aria-label="Log out"
            title="Log out"
            class="inline-flex size-11 items-center justify-center gap-1.5 whitespace-nowrap rounded-lg border border-slate-700/80 bg-slate-900/30 text-slate-300 transition hover:border-teal-400/50 hover:bg-teal-400/10 hover:text-teal-100 sm:w-auto sm:px-3"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
            <span class="hidden sm:inline">Log out</span>
          </.link>
          <.link
            :if={!@current_scope}
            navigate={~p"/users/log-in"}
            class="rounded-lg border border-slate-700 bg-slate-900/30 px-3 py-2 text-slate-300 transition hover:border-teal-400/50 hover:bg-teal-400/10 hover:text-teal-100"
          >Log in</.link>
        </nav>
      </div>
    </header>

    <main
      id="main-content"
      tabindex="-1"
      class="min-h-[calc(100vh-4rem)] bg-slate-950 px-4 py-10 text-slate-200 focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-teal-300/60 sm:px-6 lg:px-8"
    >
      <div class="mx-auto max-w-7xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <button
      :if={@jump_to_top}
      id="jump-to-top"
      type="button"
      phx-hook="JumpToTop"
      data-jump-visible="false"
      aria-label="Jump to top"
      aria-hidden="true"
      tabindex="-1"
      class="jump-to-top fixed z-50 grid size-11 place-items-center rounded-lg border border-slate-700 bg-slate-900/90 text-slate-300 shadow-xl shadow-black/30 backdrop-blur transition duration-200 hover:border-teal-400/50 hover:bg-slate-800 hover:text-teal-200 focus:outline-none focus:ring-2 focus:ring-teal-300/60"
    >
      <.icon name="hero-arrow-up" class="size-5" />
    </button>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      class="pointer-events-none fixed right-4 top-20 z-[60] flex flex-col gap-3"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc "Renders the shared settings navigation in a stable order on every settings page."
  attr :current, :string, required: true
  attr :admin?, :boolean, required: true

  def settings_nav(assigns) do
    ~H"""
    <nav
      id="settings-navigation"
      aria-label="Settings"
      class="order-first flex max-w-full overflow-x-auto rounded-xl bg-slate-900 p-1 ring-1 ring-slate-800 sm:order-none sm:self-start"
    >
      <.link
        navigate={~p"/settings/account"}
        aria-current={@current == "account" && "page"}
        class={settings_nav_class(@current == "account")}
      >
        Account
      </.link>
      <.link
        navigate={~p"/settings/integrations"}
        aria-current={@current == "integrations" && "page"}
        class={settings_nav_class(@current == "integrations")}
      >
        Integrations
      </.link>
      <.link
        :if={@admin?}
        navigate={~p"/settings/accounts"}
        aria-current={@current == "accounts" && "page"}
        class={settings_nav_class(@current == "accounts")}
      >
        Accounts
      </.link>
      <.link
        :if={@admin?}
        navigate={~p"/settings/sync"}
        aria-current={@current == "sync" && "page"}
        class={settings_nav_class(@current == "sync")}
      >
        Sync runs
      </.link>
      <.link
        :if={@admin?}
        navigate={~p"/settings/matches"}
        aria-current={@current == "matches" && "page"}
        class={settings_nav_class(@current == "matches")}
      >
        Matches
      </.link>
    </nav>
    """
  end

  defp settings_nav_class(true),
    do: "shrink-0 rounded-lg bg-teal-300 px-4 py-2 text-sm font-medium text-on-accent"

  defp settings_nav_class(false),
    do:
      "shrink-0 rounded-lg px-4 py-2 text-sm font-medium text-slate-400 transition hover:bg-teal-400/10 hover:text-teal-100"
end
