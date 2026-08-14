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

defmodule IriWeb.Settings.IntegrationsLive do
  @moduledoc "Authenticated provider-account connection and sharing settings page."

  use IriWeb, :live_view

  alias Iri.Accounts
  alias Iri.Integrations
  alias Iri.Integrations.{GOGConnectionForm, SteamConnectionForm, XboxConnectionForm}
  alias Iri.InstancePolicy
  alias Iri.Security.Redactor
  alias Iri.Sync

  @impl true
  def mount(_params, _session, socket) do
    {:ok, accounts} = Integrations.list_provider_accounts(socket.assigns.current_scope)
    {:ok, users} = Accounts.list_shareable_users(socket.assigns.current_scope)
    {:ok, steam?} = Integrations.steam_api_key_configured?(socket.assigns.current_scope)
    {:ok, igdb?} = Integrations.igdb_configured?(socket.assigns.current_scope)
    {:ok, xbox?} = Integrations.openxbl_configured?(socket.assigns.current_scope)
    if connected?(socket), do: :ok = Sync.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Integrations")
     |> assign(:users, users)
     |> assign(:mode, InstancePolicy.mode())
     |> assign(:steam_configured?, steam?)
     |> assign(:igdb_configured?, igdb?)
     |> assign(:openxbl_configured?, xbox?)
     |> assign(:steam_form, to_form(SteamConnectionForm.changeset(%SteamConnectionForm{}, %{})))
     |> assign(:gog_form, to_form(GOGConnectionForm.changeset(%GOGConnectionForm{}, %{})))
     |> assign(:xbox_form, to_form(XboxConnectionForm.changeset(%XboxConnectionForm{}, %{})))
     |> stream(:accounts, accounts)}
  end

  @impl true
  def handle_params(%{"steamid" => id}, _uri, socket) do
    {:noreply,
     assign(
       socket,
       :steam_form,
       to_form(SteamConnectionForm.changeset(%SteamConnectionForm{}, %{"profile" => id}))
     )}
  end

  def handle_params(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_event("connect_steam", %{"steam_connection_form" => params}, socket),
    do: connect(socket, :steam, params)

  def handle_event("connect_gog", %{"gog_connection_form" => params}, socket),
    do: connect(socket, :gog, params)

  def handle_event("connect_xbox", %{"xbox_connection_form" => params}, socket),
    do: connect(socket, :xbox, params)

  def handle_event("set_main_steam", %{"account_id" => id}, socket) do
    case Accounts.set_main_steam_account(socket.assigns.current_scope, id) do
      {:ok, user} ->
        {:noreply,
         socket
         |> refresh_accounts(user)
         |> put_flash(:info, "Personal Steam playtime source updated.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, internal(reason))}
    end
  end

  def handle_event("sync", %{"provider" => provider, "account_id" => id}, socket) do
    fun =
      case provider do
        "steam" -> &Sync.start_steam_sync/2
        "gog" -> &Sync.start_gog_sync/2
        "xbox" -> &Sync.start_xbox_sync/2
        _ -> nil
      end

    case fun && fun.(socket.assigns.current_scope, id) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Library sync queued.")}

      {:error, :sync_in_progress} ->
        {:noreply, put_flash(socket, :error, "A sync is already running for that library.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, internal(reason))}

      nil ->
        {:noreply, put_flash(socket, :error, "This library is imported manually.")}
    end
  end

  def handle_event("delete", %{"account_id" => id}, socket) do
    case Integrations.delete_provider_account(socket.assigns.current_scope, id) do
      {:ok, {account, pruned}} ->
        {:noreply,
         socket
         |> stream_delete(:accounts, account)
         |> put_flash(:info, removal_message(pruned))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, internal(reason))}
    end
  end

  def handle_event("access", %{"access" => params}, socket) do
    case Integrations.update_provider_account_access(
           socket.assigns.current_scope,
           params["account_id"],
           params
         ) do
      {:ok, account} ->
        {:noreply,
         socket
         |> stream_insert(:accounts, account)
         |> put_flash(:info, "Library access updated.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, internal(reason))}
    end
  end

  def handle_event("sync_igdb", params, socket) do
    options =
      if params["force"] == "true",
        do: [force: true],
        else: [compatibility_after: true]

    case Sync.start_igdb_sync(socket.assigns.current_scope, options) do
      {:ok, _} ->
        message =
          if params["force"] == "true",
            do: "IGDB metadata refresh queued.",
            else: "Game enrichment queued. Compatibility will follow."

        {:noreply, put_flash(socket, :info, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, internal(reason))}
    end
  end

  def handle_event("sync_compatibility", _, socket) do
    case Sync.start_compatibility_sync(socket.assigns.current_scope, force: true) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Full Steam compatibility refresh queued.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, internal(reason))}
    end
  end

  @impl true
  def handle_info({:sync_run_updated, _}, socket) do
    {:ok, accounts} = Integrations.list_provider_accounts(socket.assigns.current_scope)
    {:noreply, stream(socket, :accounts, accounts, reset: true)}
  end

  def handle_info({:scheduled_task_updated, _}, socket), do: {:noreply, socket}

  defp connect(socket, provider, params) do
    result =
      case provider do
        :steam -> Integrations.connect_steam(socket.assigns.current_scope, params)
        :gog -> Integrations.connect_gog(socket.assigns.current_scope, params)
        :xbox -> Integrations.connect_xbox(socket.assigns.current_scope, params)
      end

    case result do
      {:ok, %{account: account, followed: true} = details} ->
        {:noreply,
         socket
         |> refresh_accounts(Map.get(details, :user, socket.assigns.current_scope.user))
         |> reset_form(provider)
         |> put_flash(
           :info,
           "#{account.display_name} is already connected by #{owner_name(account)}; " <>
             "it now also appears in your library."
         )}

      {:ok, %{account: account} = details} ->
        sync =
          case provider do
            :steam -> Sync.start_steam_sync(socket.assigns.current_scope, account.id)
            :gog -> Sync.start_gog_sync(socket.assigns.current_scope, account.id)
            :xbox -> Sync.start_xbox_sync(socket.assigns.current_scope, account.id)
          end

        text =
          if match?({:ok, _}, sync),
            do: "Connected #{account.display_name} and queued its first import.",
            else: "Connected #{account.display_name}. You can sync it below."

        {:noreply,
         socket
         |> refresh_accounts(Map.get(details, :user, socket.assigns.current_scope.user))
         |> reset_form(provider)
         |> put_flash(:info, text)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, form_key(provider), to_form(Map.put(changeset, :action, :insert)))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, public_error(provider, reason))}
    end
  end

  defp reset_form(socket, :steam),
    do:
      assign(
        socket,
        :steam_form,
        to_form(SteamConnectionForm.changeset(%SteamConnectionForm{}, %{}))
      )

  defp reset_form(socket, :gog),
    do: assign(socket, :gog_form, to_form(GOGConnectionForm.changeset(%GOGConnectionForm{}, %{})))

  defp reset_form(socket, :xbox),
    do:
      assign(
        socket,
        :xbox_form,
        to_form(XboxConnectionForm.changeset(%XboxConnectionForm{}, %{}))
      )

  defp owner_name(%{owner_user: %{username: username}}) when is_binary(username), do: username
  defp owner_name(_account), do: "another user"

  defp refresh_accounts(socket, %Iri.Accounts.User{} = user) do
    current_scope = Iri.Accounts.Scope.for_user(user)

    {:ok, accounts} = Integrations.list_provider_accounts(current_scope)

    socket
    |> assign(:current_scope, current_scope)
    |> stream(:accounts, accounts, reset: true)
  end

  defp form_key(:steam), do: :steam_form
  defp form_key(:gog), do: :gog_form
  defp form_key(:xbox), do: :xbox_form

  defp public_error(:steam, :not_configured), do: "Set STEAM_WEB_API_KEY and restart Iri."

  defp public_error(:steam, :steam_identity_taken),
    do: "That Steam account is already linked to another IRI user."

  defp public_error(:xbox, :not_configured), do: "Set OPENXBL_API_KEY and restart Iri."

  defp public_error(:gog, :invalid_gog_profile), do: "Enter a public GOG username or profile URL."
  defp public_error(_, %Iri.Integrations.Error{message: message}), do: message
  defp public_error(_, reason), do: internal(reason)
  defp internal(reason), do: reason |> Redactor.redact_inspect() |> String.slice(0, 300)

  defp removal_message(%{games: 0}), do: "Library removed."

  defp removal_message(%{games: games}) do
    "Library removed, along with #{games} #{if games == 1, do: "game", else: "games"} no longer in any library."
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto w-full max-w-6xl space-y-8">
        <header class="flex flex-col gap-5 border-b border-slate-800 pb-6 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <h1 class="text-3xl font-semibold tracking-tight text-heading">
              Integrations
            </h1><p class="mt-2 text-sm text-slate-400">
              Connect and update your game libraries.
            </p>
          </div><Layouts.settings_nav
            current="integrations"
            admin?={@current_scope.role == :admin}
          />
        </header>

        <section aria-labelledby="connected-libraries-heading">
          <div class="border-b border-slate-800 pb-3">
            <h2 id="connected-libraries-heading" class="text-lg font-semibold text-heading">
              Your libraries
            </h2>
          </div>
          <div
            id="provider-accounts"
            phx-update="stream"
            class="divide-y divide-slate-800"
          >
            <p
              id="provider-accounts-empty"
              class="hidden py-10 text-center text-sm text-slate-500 only:block"
            >
              No libraries connected yet.
            </p>
            <article
              :for={{id, account} <- @streams.accounts}
              id={id}
              class="group py-4"
            >
              <div class="flex items-center gap-3">
                <div class="min-w-0 flex-1">
                  <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
                    <p class="truncate font-semibold text-slate-100">
                      {account.display_name || account.external_user_id}
                    </p>
                    <span
                      :if={
                        account.provider == :steam &&
                          @current_scope.user.main_steam_account_id == account.id
                      }
                      class="inline-flex items-center gap-1 text-[0.68rem] font-semibold text-teal-100"
                    >
                      <.icon name="hero-star-solid" class="size-3" /> Main
                    </span>
                  </div>
                  <p class="mt-0.5 truncate text-xs uppercase tracking-wider text-slate-500">
                    {account.provider} · {String.replace(account.sync_status, "_", " ")}
                    <span :if={account.owner_user_id != @current_scope.user.id}>
                      · linked from {owner_name(account)}
                    </span>
                  </p>
                </div>
                <div class="flex shrink-0 items-center gap-1.5">
                  <button
                    :if={
                      account.provider == :steam &&
                        @current_scope.user.main_steam_account_id != account.id
                    }
                    id={"main-steam-account-#{account.id}"}
                    type="button"
                    phx-click="set_main_steam"
                    phx-value-account_id={account.id}
                    aria-label={"Mark #{account.display_name || account.external_user_id} as my library"}
                    title="Mark as mine (shows first in filters)"
                    class="grid size-10 place-items-center rounded-xl border border-transparent text-slate-500 opacity-100 transition hover:border-teal-400/30 hover:bg-teal-400/10 hover:text-teal-200 focus-visible:border-teal-400/30 focus-visible:text-teal-200 sm:opacity-0 sm:group-hover:opacity-100 sm:group-focus-within:opacity-100"
                  >
                    <.icon name="hero-star" class="size-4" />
                  </button>
                  <button
                    :if={
                      account.owner_user_id == @current_scope.user.id &&
                        account.provider in [:steam, :gog, :xbox]
                    }
                    id={"sync-account-#{account.id}"}
                    type="button"
                    phx-click="sync"
                    phx-value-provider={account.provider}
                    phx-value-account_id={account.id}
                    aria-label={"Sync #{account.display_name || account.external_user_id}"}
                    title="Sync now"
                    class="grid size-10 place-items-center rounded-xl border border-slate-700 text-slate-300 transition hover:border-teal-400/50 hover:bg-teal-400/10 hover:text-teal-100"
                  ><.icon name="hero-arrow-path" class="size-4" /></button><button
                    :if={account.owner_user_id == @current_scope.user.id}
                    id={"delete-account-#{account.id}"}
                    type="button"
                    phx-click="delete"
                    phx-value-account_id={account.id}
                    aria-label={"Remove #{account.display_name || account.external_user_id}"}
                    title="Remove library"
                    data-confirm="Remove this library and its ownership rows?"
                    class="grid size-10 place-items-center rounded-xl border border-slate-800 text-slate-400 hover:border-rose-400/30 hover:text-rose-300"
                  ><.icon name="hero-trash" class="size-4" /></button>
                </div>
              </div>
              <details
                :if={account.owner_user_id == @current_scope.user.id}
                class="mt-1 text-sm text-slate-400"
              >
                <summary class="inline-flex min-h-8 cursor-pointer list-none items-center gap-1.5 rounded-lg px-2 text-xs transition hover:bg-slate-800 hover:text-slate-200">
                  <.icon name="hero-user-group" class="size-3.5" />
                  {visibility_label(account.sharing_policy, @mode)}
                  <.icon name="hero-chevron-down" class="size-3" />
                </summary>
                <.form
                  for={
                    to_form(
                      %{
                        "account_id" => account.id,
                        "sharing_policy" => to_string(account.sharing_policy),
                        "shared_user_ids" => Enum.map(account.shared_users, & &1.id)
                      },
                      as: :access
                    )
                  }
                  id={"access-#{account.id}"}
                  phx-change="access"
                  class="mt-2 grid gap-3 border-l border-slate-700 py-2 pl-4 sm:grid-cols-[15rem_1fr]"
                >
                  <input type="hidden" name="access[account_id]" value={account.id} /><.input
                    type="select"
                    field={
                      to_form(%{"sharing_policy" => to_string(account.sharing_policy)}, as: :access)[
                        :sharing_policy
                      ]
                    }
                    label="Library visibility"
                    options={visibility_options(@mode)}
                  /><div :if={account.sharing_policy == :selected_users} class="pt-7">
                    <label
                      :for={user <- @users}
                      class="mr-4 inline-flex items-center gap-2 text-sm text-slate-300"
                    ><input
                      type="checkbox"
                      name="access[shared_user_ids][]"
                      value={user.id}
                      checked={user.id in Enum.map(account.shared_users, & &1.id)}
                      class="rounded border-slate-700 bg-slate-900"
                    />{user.username}</label>
                  </div>
                </.form>
              </details>
            </article>
          </div>
        </section>

        <section aria-label="Connect a library" class="grid gap-6 lg:grid-cols-3">
          <.connection_card
            title="Steam"
            configured={@steam_configured?}
            hint={
              if @steam_configured? do
                "Import games and playtime from a public Steam profile."
              else
                "Steam imports need a server-side API key."
              end
            }
          >
            <p
              :if={!@steam_configured?}
              id="steam-api-key-setup"
              class="mb-3 text-sm leading-5 text-slate-400"
            >
              Create a <a
                href="https://steamcommunity.com/dev/apikey"
                target="_blank"
                rel="noreferrer"
                class="font-medium text-sky-300 underline decoration-sky-300/50 underline-offset-2 transition hover:text-sky-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-sky-300"
              >Steam Web API key</a>, set <code class="rounded bg-slate-900 px-1.5 py-0.5 text-slate-200">STEAM_WEB_API_KEY</code>, then restart IRI.
            </p>
            <.form
              for={@steam_form}
              id="connect-steam-form"
              phx-submit="connect_steam"
              class="space-y-3"
            >
              <.input
                field={@steam_form[:profile]}
                label="Steam ID or profile URL"
                disabled={!@steam_configured?}
              />
              <.button id="connect-steam-button" class="w-full" disabled={!@steam_configured?}>
                Connect Steam
              </.button>
            </.form>
            <.link
              :if={@steam_configured?}
              href={~p"/auth/steam"}
              class="mt-3 block text-center text-sm text-sky-300 underline"
            >Choose account with Steam</.link>
          </.connection_card>
          <.connection_card
            title="GOG"
            configured={true}
            hint="Import games and playtime from a public GOG profile."
          >
            <.form for={@gog_form} id="connect-gog-form" phx-submit="connect_gog" class="space-y-3">
              <.input field={@gog_form[:profile]} label="GOG username or profile URL" /><.button class="w-full">Connect GOG</.button>
            </.form>
          </.connection_card>
          <.connection_card
            title="Xbox"
            configured={@openxbl_configured?}
            hint={
              if @openxbl_configured? do
                "Import the games played by your Xbox account through OpenXBL."
              else
                "Xbox imports need a server-side API key."
              end
            }
          >
            <p
              :if={!@openxbl_configured?}
              id="openxbl-api-key-setup"
              class="mb-3 text-sm leading-5 text-slate-400"
            >
              Create an <a
                href="https://xbl.io/"
                target="_blank"
                rel="noreferrer"
                class="font-medium text-sky-300 underline decoration-sky-300/50 underline-offset-2 transition hover:text-sky-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-sky-300"
              >OpenXBL API key</a>, set <code class="rounded bg-slate-900 px-1.5 py-0.5 text-slate-200">OPENXBL_API_KEY</code>, then restart IRI.
            </p>
            <.form
              for={@xbox_form}
              id="connect-xbox-form"
              phx-submit="connect_xbox"
              class="space-y-3"
            >
              <.input
                field={@xbox_form[:gamertag]}
                label="Gamertag"
                placeholder="Gamertag or Gamertag#1234"
                disabled={!@openxbl_configured?}
              />
              <.button id="connect-xbox-button" class="w-full" disabled={!@openxbl_configured?}>
                Connect Xbox
              </.button>
            </.form>
          </.connection_card>
        </section>

        <section aria-labelledby="other-imports-heading">
          <h2 id="other-imports-heading" class="text-lg font-semibold text-heading">
            Other imports
          </h2>
          <div class="mt-3 grid gap-x-6 sm:grid-cols-3">
            <.import_link
              href={~p"/settings/integrations/epic/import"}
              title="Epic Games"
              text="Upload Legendary JSON"
              icon="hero-arrow-up-tray"
            /><.import_link
              href={~p"/settings/integrations/psn/import"}
              title="PlayStation"
              text="Import purchased and played games"
              icon="hero-command-line"
            /><.import_link
              href={~p"/library/add"}
              title="Custom games"
              text="Search or batch-add IGDB IDs"
              icon="hero-plus"
            />
          </div>
        </section>

        <section
          :if={@current_scope.role == :admin}
          class="border-t border-slate-800 pt-6"
        >
          <h2 class="text-lg font-semibold text-heading">Global metadata maintenance</h2><p class="mt-1 text-sm text-slate-400">
            Update game information and Steam Deck compatibility.
          </p><div class="mt-5 flex flex-wrap gap-3">
            <.button
              id="enrich-new-games"
              phx-click="sync_igdb"
            >Enrich new games</.button><.button
              id="refresh-all-metadata"
              phx-click="sync_igdb"
              phx-value-force="true"
            >Refresh all metadata</.button><.button
              id="refresh-all-compatibility"
              phx-click="sync_compatibility"
              data-confirm="Refresh compatibility for every owned Steam game? This can take a while."
            >Refresh all compatibility</.button>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp visibility_options(:family),
    do: [
      {"Family (default)", "inherit"},
      {"Only selected users", "selected_users"},
      {"Everyone", "everyone"}
    ]

  defp visibility_options(:public),
    do: [
      {"Private (default)", "inherit"},
      {"Only selected users", "selected_users"},
      {"Everyone", "everyone"}
    ]

  defp visibility_label(:inherit, :family), do: "Family visibility"
  defp visibility_label(:inherit, :public), do: "Private"
  defp visibility_label(:selected_users, _mode), do: "Selected users"
  defp visibility_label(:everyone, _mode), do: "Everyone"

  attr :title, :string, required: true
  attr :configured, :boolean, required: true
  attr :hint, :string, required: true
  slot :inner_block, required: true

  defp connection_card(assigns) do
    ~H"""
    <article class="border-t border-slate-800 pt-5">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold text-heading">{@title}</h2><span
          class={[
            "size-2 rounded-full",
            if(@configured, do: "bg-emerald-300", else: "bg-rose-300")
          ]}
          title={if(@configured, do: "Configured", else: "Not configured")}
        ><span class="sr-only">{if @configured, do: "Configured", else: "Not configured"}</span></span>
      </div>
      <p class="mt-2 min-h-10 text-sm leading-5 text-slate-400">{@hint}</p><div class="mt-5">
        {render_slot(@inner_block)}
      </div>
    </article>
    """
  end

  attr :href, :string, required: true
  attr :title, :string, required: true
  attr :text, :string, required: true
  attr :icon, :string, required: true

  defp import_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="group flex items-start gap-3 border-t border-slate-800 py-4 transition hover:border-teal-400/50"
    ><span class="mt-0.5 text-slate-500 transition group-hover:text-teal-100"><.icon
      name={@icon}
      class="size-5"
    /></span><span><strong class="block text-slate-100 transition group-hover:text-heading">{@title}</strong><span class="text-sm text-slate-500">{@text}</span></span></.link>
    """
  end
end
