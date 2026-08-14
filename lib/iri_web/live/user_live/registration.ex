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

defmodule IriWeb.UserLive.Registration do
  @moduledoc "Optional-authentication local account registration page."

  use IriWeb, :live_view

  alias Iri.Accounts
  alias Iri.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm rounded-3xl border border-slate-800 bg-slate-950/70 p-6 shadow-2xl shadow-black/20 sm:p-8">
        <div class="text-center">
          <.header>
            Register for an account
            <:subtitle>
              Already registered?
              <.link
                navigate={~p"/users/log-in"}
                class="font-semibold text-teal-300 underline decoration-teal-400/50 underline-offset-4 transition hover:text-teal-200"
              >
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <p
          :if={@first_user_registration? && @registration_open?}
          id="first-user-admin-note"
          class="mt-6 rounded-xl border border-teal-400/20 bg-teal-400/5 px-4 py-3 text-sm leading-5 text-teal-100"
        >
          This is the first account on this IRI server, so it will be the administrator.
        </p>

        <section
          :if={!@registration_open?}
          id="registration-closed"
          class="mt-6 rounded-2xl border border-slate-800 bg-slate-900/60 p-5 text-sm leading-6 text-slate-300"
        >
          <p class="font-semibold text-heading">Registration is managed by the administrator.</p>
          <p class="mt-2 text-slate-400">
            This IRI server is in Family mode. Ask the administrator to create your account.
          </p>
          <.link
            navigate={~p"/users/log-in"}
            class="mt-4 inline-flex min-h-11 items-center rounded-xl border border-slate-700 px-4 py-2 font-semibold text-slate-100 transition hover:bg-slate-800"
          >
            Log in
          </.link>
        </section>

        <.form
          :if={@registration_open?}
          for={@form}
          id="registration_form"
          action={~p"/users/log-in?_action=registered"}
          phx-submit="save"
          phx-change="validate"
          phx-trigger-action={@trigger_submit}
          class="mt-6 space-y-5"
        >
          <input type="hidden" name="user[remember_me]" value="true" />
          <.input
            field={@form[:username]}
            type="text"
            label="Username"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <p class="text-xs leading-5 text-slate-500">
            Prefer Steam? You can create your account directly from the login page without a password.
          </p>
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="new-password"
            required
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Confirm password"
            autocomplete="new-password"
            required
          />

          <.button phx-disable-with="Creating account..." class="w-full">
            Create account
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: IriWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_registration(%User{}, %{}, validate_unique: false)

    {:ok,
     socket
     |> assign(:page_title, "Register")
     |> assign(:trigger_submit, false)
     |> assign(:first_user_registration?, Accounts.first_user_registration?())
     |> assign(:registration_open?, Accounts.registration_open?())
     |> assign_form(changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(:form, to_form(user_params, as: "user"))
         |> assign(:trigger_submit, true)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :registration_closed} ->
        {:noreply,
         socket
         |> assign(:registration_open?, false)
         |> put_flash(:error, "Registration is managed by the administrator.")}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      Accounts.change_user_registration(%User{}, user_params,
        validate_unique: false,
        hash_password: false
      )

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
