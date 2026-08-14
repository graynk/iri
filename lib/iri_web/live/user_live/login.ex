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

defmodule IriWeb.UserLive.Login do
  @moduledoc "Optional-authentication password and Steam sign-in page."

  use IriWeb, :live_view

  alias Iri.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-6 rounded-3xl border border-slate-800 bg-slate-950/70 p-6 shadow-2xl shadow-black/20 sm:p-8">
        <div class="text-center">
          <.header>
            Log in
            <:subtitle>
              <%= if @current_scope do %>
                You need to reauthenticate to perform sensitive actions on your account.
              <% else %>
                Don't have an account? <.link
                  navigate={~p"/users/register"}
                  class="font-semibold text-teal-300 underline decoration-teal-400/50 underline-offset-4 transition hover:text-teal-200"
                  phx-no-format
                >Sign up</.link> for an account now.
              <% end %>
            </:subtitle>
          </.header>
        </div>

        <p
          :if={@first_user_registration?}
          id="first-user-admin-note"
          class="rounded-xl border border-teal-400/20 bg-teal-400/5 px-4 py-3 text-sm leading-5 text-teal-100"
        >
          The first account created on this IRI server becomes its administrator.
        </p>

        <.link
          id="login-with-steam"
          href={~p"/users/log-in/steam"}
          class="flex min-h-12 w-full items-center justify-center gap-2 rounded-xl bg-[#1b2838] px-4 py-3 text-sm font-semibold text-white ring-1 ring-sky-300/20 transition hover:bg-[#243b55]"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Continue with Steam
        </.link>

        <div class="flex items-center gap-3 text-xs uppercase tracking-wider text-slate-600">
          <span class="h-px flex-1 bg-slate-800" /> or use a local account
          <span class="h-px flex-1 bg-slate-800" />
        </div>

        <.form
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
          class="space-y-5"
        >
          <.input
            readonly={!!@current_scope}
            field={@form[:username]}
            type="text"
            label="Username"
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
          />
          <.button class="w-full" name={@form[:remember_me].name} value="true">
            Log in <span aria-hidden="true">→</span>
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    username =
      Phoenix.Flash.get(socket.assigns.flash, :username) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:username)])

    form = to_form(%{"username" => username}, as: "user")

    {:ok,
     socket
     |> assign(:page_title, "Log in")
     |> assign(
       form: form,
       trigger_submit: false,
       first_user_registration?: Accounts.first_user_registration?()
     )}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
