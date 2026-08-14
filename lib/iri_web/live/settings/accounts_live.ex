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

defmodule IriWeb.Settings.AccountsLive do
  @moduledoc "Administrator user-account and library-access management page."

  use IriWeb, :live_view

  alias Iri.Accounts
  alias Iri.Accounts.User
  alias Iri.InstancePolicy

  @impl true
  def mount(_params, _session, socket) do
    {:ok, users} = Accounts.list_users(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Accounts")
     |> assign(:mode_label, InstancePolicy.label())
     |> assign(:public_registration?, InstancePolicy.public_registration?())
     |> assign(:form, registration_form())
     |> stream(:users, users)}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      %User{}
      |> Accounts.change_user_registration(params,
        validate_unique: false,
        hash_password: false
      )
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
  end

  def handle_event("create", %{"user" => params}, socket) do
    case Accounts.create_user(socket.assigns.current_scope, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:form, registration_form())
         |> stream_insert(:users, user)
         |> put_flash(:info, "Created #{user.username}. Give them the initial password securely.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :form, to_form(Map.put(changeset, :action, :insert), as: :user))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Administrator access is required.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto w-full max-w-6xl space-y-8">
        <header class="flex flex-col gap-5 border-b border-slate-800 pb-6 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.24em] text-teal-300">
              Admin settings
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-heading">Accounts</h1>
            <p id="instance-mode" class="mt-2 text-sm leading-6 text-slate-400">
              {@mode_label}. {if @public_registration?,
                do: "People may create their own accounts.",
                else: "Only administrators create accounts after first setup."}
            </p>
          </div>
          <Layouts.settings_nav current="accounts" admin?={true} />
        </header>

        <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_24rem]">
          <section class="overflow-hidden rounded-3xl border border-slate-800 bg-slate-950/60">
            <div class="border-b border-slate-800 px-6 py-5">
              <h2 class="text-lg font-semibold text-heading">IRI users</h2>
            </div>
            <ul id="users" phx-update="stream" class="divide-y divide-slate-800">
              <li
                id="users-empty"
                class="hidden px-6 py-10 text-center text-sm text-slate-500 only:block"
              >
                No users yet.
              </li>
              <li
                :for={{id, user} <- @streams.users}
                id={id}
                class="flex items-center justify-between gap-4 px-6 py-4"
              >
                <div class="min-w-0">
                  <p class="truncate font-semibold text-slate-100">{user.username}</p>
                  <p class="mt-1 text-xs text-slate-500">
                    {if user.steam_id, do: "Steam linked", else: "Local account"}
                  </p>
                </div>
                <span class="rounded-full bg-slate-800 px-3 py-1 text-xs font-medium text-slate-300">
                  {user.role}
                </span>
              </li>
            </ul>
          </section>

          <aside class="rounded-3xl border border-slate-800 bg-slate-950/80 p-6">
            <h2 class="text-lg font-semibold text-heading">Create account</h2>
            <p class="mt-1 text-sm leading-6 text-slate-400">
              Set an initial password and give it directly to the person. They can change it after login.
            </p>
            <.form
              for={@form}
              id="admin-create-user-form"
              phx-change="validate"
              phx-submit="create"
              class="mt-5 space-y-4"
            >
              <.input field={@form[:username]} label="Username" autocomplete="off" required />
              <.input
                field={@form[:password]}
                type="password"
                label="Initial password"
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
              <.button id="admin-create-user" phx-disable-with="Creating…" class="w-full">
                Create account
              </.button>
            </.form>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp registration_form do
    %User{}
    |> Accounts.change_user_registration(%{}, validate_unique: false)
    |> to_form(as: :user)
  end
end
