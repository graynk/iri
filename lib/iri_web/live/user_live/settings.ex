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

defmodule IriWeb.UserLive.Settings do
  @moduledoc "Authenticated account, password, Steam identity, and sensitive-media preferences page."

  use IriWeb, :live_view

  alias Iri.Accounts
  alias Iri.Media.Policy

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto w-full max-w-6xl space-y-8">
        <header
          id="account-settings-header"
          class="flex flex-col gap-5 border-b border-slate-800 pb-6 sm:flex-row sm:items-end sm:justify-between"
        >
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.24em] text-teal-300">
              {if @current_scope.role == :admin, do: "Admin settings", else: "Settings"}
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-heading">Account settings</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-slate-400">
              Manage your profile, media preferences, and sign-in methods.
            </p>
          </div>
          <Layouts.settings_nav current="account" admin?={@current_scope.role == :admin} />
        </header>

        <div class="mx-auto w-full max-w-xl space-y-8 rounded-3xl border border-slate-800 bg-slate-950/70 p-6 shadow-2xl shadow-black/20 sm:p-8">
          <div class="text-center">
            <span
              id="account-role"
              class="inline-flex rounded-full bg-slate-800 px-3 py-1 text-xs font-semibold capitalize text-slate-300 ring-1 ring-slate-700"
            >
              {@current_scope.role} account
            </span>
          </div>

          <.form
            for={@username_form}
            id="username-form"
            phx-submit="update_username"
            phx-change="validate_username"
            class="space-y-5"
          >
            <.input
              field={@username_form[:username]}
              type="text"
              label="Username"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.button variant="primary" phx-disable-with="Saving...">Save username</.button>
          </.form>

          <div class="h-px bg-slate-800" />

          <.form
            for={@sensitive_media_form}
            id="sensitive-media-form"
            phx-submit="update_sensitive_media"
            class="space-y-4"
          >
            <.input
              field={@sensitive_media_form[:sensitive_media_mode]}
              type="select"
              label="Sensitive media"
              options={sensitive_media_options()}
            />
            <.button variant="primary" phx-disable-with="Saving...">Save preference</.button>
          </.form>

          <div class="h-px bg-slate-800" />

          <section id="steam-sign-in" class="rounded-2xl border border-slate-800 bg-slate-900/60 p-5">
            <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <h2 class="font-semibold text-slate-100">Steam sign-in</h2>
                <p class="mt-1 text-sm text-slate-400">
                  <%= if @current_scope.user.steam_id do %>
                    Linked to SteamID {@current_scope.user.steam_id}
                  <% else %>
                    Link Steam to use it instead of a local password.
                  <% end %>
                </p>
              </div>
              <.link
                :if={!@current_scope.user.steam_id}
                id="link-steam-sign-in"
                href={~p"/users/log-in/steam"}
                class="inline-flex min-h-10 items-center justify-center rounded-xl bg-[#1b2838] px-4 py-2 text-sm font-semibold text-white ring-1 ring-sky-300/20 transition hover:bg-[#243b55]"
              >
                Link Steam
              </.link>
              <span
                :if={@current_scope.user.steam_id}
                class="rounded-full bg-emerald-400/10 px-3 py-1 text-xs font-semibold text-emerald-300 ring-1 ring-emerald-400/20"
              >Linked</span>
            </div>
          </section>

          <div class="h-px bg-slate-800" />

          <.form
            for={@password_form}
            id="password_form"
            action={~p"/settings/update-password"}
            method="post"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
            class="space-y-5"
          >
            <input
              name={@password_form[:username].name}
              type="hidden"
              id="hidden-user-username"
              spellcheck="false"
              value={@current_username}
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              spellcheck="false"
              required
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              spellcheck="false"
            />
            <.button variant="primary" phx-disable-with="Saving...">
              Save Password
            </.button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    username_changeset = Accounts.change_user_username(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)
    sensitive_media_changeset = Accounts.change_user_sensitive_media(user)

    socket =
      socket
      |> assign(:page_title, "Account settings")
      |> assign(:current_username, user.username)
      |> assign(:username_form, to_form(username_changeset))
      |> assign(:sensitive_media_form, to_form(sensitive_media_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_username", params, socket) do
    %{"user" => user_params} = params

    username_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_username(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, username_form: username_form)}
  end

  def handle_event("update_username", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    case Accounts.update_user_username(user, user_params) do
      {:ok, updated_user} ->
        current_scope = %{socket.assigns.current_scope | user: updated_user}

        {:noreply,
         socket
         |> assign(:current_scope, current_scope)
         |> assign(:current_username, updated_user.username)
         |> assign(:username_form, to_form(Accounts.change_user_username(updated_user)))
         |> put_flash(:info, "Username updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :username_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_sensitive_media", %{"user" => params}, socket) do
    case Accounts.update_user_sensitive_media(socket.assigns.current_scope, params) do
      {:ok, updated_user} ->
        current_scope = %{socket.assigns.current_scope | user: updated_user}

        {:noreply,
         socket
         |> assign(:current_scope, current_scope)
         |> assign(
           :sensitive_media_form,
           to_form(Accounts.change_user_sensitive_media(updated_user))
         )
         |> put_flash(:info, "Sensitive media preference updated.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :sensitive_media_form, to_form(changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update that preference.")}
    end
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  defp sensitive_media_options do
    default = Policy.default_mode() |> Atom.to_string() |> String.capitalize()

    [
      {"Server default (#{default})", "inherit"},
      {"Blur until revealed", "blur"},
      {"Hide", "hide"},
      {"Show", "allow"}
    ]
  end
end
