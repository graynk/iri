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

defmodule IriWeb.CustomGameLive do
  @moduledoc "Authenticated IGDB search and batch-add flow for manually owned games."

  use IriWeb, :live_view

  alias Iri.Integrations.Custom
  alias Iri.Integrations.Steam.ManualLibrary

  @impl true
  def mount(params, _session, socket) do
    replacement = replacement_game(socket.assigns.current_scope, params["replace"])

    {:ok,
     socket
     |> assign(:page_title, if(replacement, do: "Change custom game", else: "Add games"))
     |> assign(:replacement, replacement)
     |> assign(:search_form, to_form(%{"query" => ""}, as: :search))
     |> assign(:batch_form, to_form(%{"ids" => ""}, as: :batch))
     |> assign(:steam_form, to_form(%{"app_id" => ""}, as: :steam))
     |> assign(:result_lookup, %{})
     |> stream_configure(:results, dom_id: &"igdb-result-#{&1["id"]}")
     |> stream(:results, [])}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    case Custom.search(socket.assigns.current_scope, query) do
      {:ok, results} ->
        {:noreply,
         socket
         |> assign(:result_lookup, Map.new(results, &{&1["id"], &1}))
         |> stream(:results, results, reset: true)
         |> assign(:search_form, to_form(%{"query" => query}, as: :search))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, message(reason))}
    end
  end

  def handle_event("add", %{"igdb_id" => id}, socket) do
    if socket.assigns.replacement do
      replace_custom_game(socket, id)
    else
      add_custom_game(socket, id)
    end
  end

  def handle_event("add_steam", %{"steam" => %{"app_id" => app_id}}, socket) do
    case ManualLibrary.add(socket.assigns.current_scope, app_id) do
      {:ok, %{status: :added, source: source}} ->
        {:noreply,
         socket
         |> assign(:steam_form, to_form(%{"app_id" => ""}, as: :steam))
         |> put_flash(
           :info,
           "#{source.source_title} added to your Steam library. Metadata enrichment was queued."
         )}

      {:ok, %{status: :already_owned, source: source}} ->
        {:noreply,
         socket
         |> assign(:steam_form, to_form(%{"app_id" => app_id}, as: :steam))
         |> put_flash(:info, "#{source.source_title} is already in that Steam library.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:steam_form, to_form(%{"app_id" => app_id}, as: :steam))
         |> put_flash(:error, message(reason))}
    end
  end

  def handle_event("remove", %{"igdb_id" => id}, socket) do
    case Custom.remove_igdb_id(socket.assigns.current_scope, String.to_integer(id)) do
      {:ok, %{removed: removed}} when removed > 0 ->
        {:noreply, refresh_result_ownership(socket)}

      {:ok, _result} ->
        {:noreply,
         socket
         |> refresh_result_ownership()
         |> put_flash(:info, "That custom game is no longer in your library.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, message(reason))}
    end
  end

  def handle_event("batch", %{"batch" => %{"ids" => input}}, socket) do
    with {:ok, ids} <- Custom.parse_ids(input),
         {:ok, counts} <- Custom.add_ids(socket.assigns.current_scope, ids) do
      {:noreply,
       socket
       |> assign(:batch_form, to_form(%{"ids" => input}, as: :batch))
       |> refresh_result_ownership()
       |> put_flash(:info, batch_message(counts))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, message(reason))}
    end
  end

  defp add_custom_game(socket, id) do
    case Custom.add_ids(socket.assigns.current_scope, [String.to_integer(id)]) do
      {:ok, %{added: 1}} ->
        {:noreply, refresh_result_ownership(socket)}

      {:ok, %{already_owned: 1}} ->
        {:noreply,
         socket
         |> refresh_result_ownership()
         |> put_flash(:info, "That game is already in your library.")}

      {:ok, _counts} ->
        {:noreply, put_flash(socket, :error, "IGDB did not return that game.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, message(reason))}
    end
  end

  defp replace_custom_game(socket, id) do
    case Custom.replace_game(
           socket.assigns.current_scope,
           socket.assigns.replacement.id,
           id
         ) do
      {:ok, %{game: game}} ->
        {:noreply, push_navigate(socket, to: ~p"/games/#{game.slug}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto w-full max-w-5xl space-y-8">
        <header id="add-games-header" class="border-b border-slate-800 pb-6">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[.22em] text-teal-300">Library</p><h1 class="mt-2 text-3xl font-semibold text-heading">
              {if @replacement, do: "Change custom game", else: "Add games"}
            </h1>
            <p :if={@replacement} class="mt-2 text-sm text-slate-400">
              Current selection: {@replacement.title}
            </p>
          </div>
        </header>

        <p :if={!@replacement} id="add-games-import-hint" class="-mt-4 text-sm text-slate-400">
          This adds games one at a time. To import a whole library instead,
          <.link
            navigate={~p"/settings/integrations"}
            class="font-semibold text-teal-300 underline decoration-teal-400/50 underline-offset-4 transition hover:text-teal-200"
          >
            connect a provider account
          </.link>
          .
        </p>

        <section class="rounded-3xl border border-slate-800 bg-slate-950/60 p-6">
          <h2 class="text-lg font-semibold text-heading">
            {if @replacement, do: "Find the correct IGDB game", else: "Search IGDB"}
          </h2>
          <.form for={@search_form} id="igdb-game-search" phx-submit="search" class="mt-4 flex gap-3">
            <div class="min-w-0 flex-1">
              <.search_input
                field={@search_form[:query]}
                id="igdb-game-search-query"
                aria-label="Game title"
                placeholder="Search by title…"
                class="min-h-11 w-full rounded-xl border border-slate-700 bg-slate-900 pl-4 pr-11 text-slate-100"
              />
            </div>
            <.button id="search-igdb-games">Search</.button>
          </.form>
          <div
            id="igdb-search-results"
            phx-update="stream"
            class="mt-5 divide-y divide-slate-800"
          >
            <article
              :for={{dom_id, game} <- @streams.results}
              id={dom_id}
              class="flex flex-col gap-4 py-5 sm:flex-row sm:items-center sm:justify-between"
            >
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
                  <p class="font-medium text-slate-100">{game["name"]}</p><span
                    :if={release_year(game)}
                    class="text-sm text-slate-500"
                  >{release_year(game)}</span>
                </div>
                <p
                  :if={developer_names(game) != ""}
                  data-role="developer"
                  class="mt-1 text-sm font-medium text-teal-300/90"
                >
                  {developer_names(game)}
                </p>
                <p
                  data-role="summary"
                  class="mt-2 line-clamp-3 max-w-3xl text-sm leading-6 text-slate-300"
                >
                  {game["summary"] || "No description available."}
                </p>
                <p class="mt-2 text-xs text-slate-500">
                  {result_metadata(game)}
                </p>
              </div>
              <%= cond do %>
                <% @replacement && game["id"] == @replacement.igdb_id -> %>
                  <span class="inline-flex min-h-11 shrink-0 items-center gap-2 self-start rounded-xl bg-slate-800 px-4 py-2 text-sm font-semibold text-slate-300 ring-1 ring-slate-700 sm:self-center">
                    <.icon name="hero-check" class="size-4 text-teal-300" /> Current selection
                  </span>
                <% @replacement -> %>
                  <button
                    id={"replace-custom-game-#{game["id"]}"}
                    type="button"
                    phx-click="add"
                    phx-value-igdb_id={game["id"]}
                    phx-disable-with="Changing…"
                    class="min-h-11 shrink-0 self-start rounded-xl border border-teal-400/40 px-5 py-2 text-sm font-semibold text-teal-200 transition hover:bg-teal-400/10 disabled:cursor-wait disabled:opacity-60 sm:self-center"
                  >Use this game</button>
                <% game["custom_owned"] -> %>
                  <button
                    type="button"
                    phx-click="remove"
                    phx-value-igdb_id={game["id"]}
                    data-confirm="Remove this custom game from your library?"
                    class="inline-flex min-h-11 shrink-0 items-center gap-2 self-start rounded-xl border border-rose-400/30 px-4 py-2 text-sm font-semibold text-rose-200 transition hover:bg-rose-400/10 sm:self-center"
                  >
                    <.icon name="hero-trash" class="size-4" /> Remove
                  </button>
                <% game["owned"] -> %>
                  <span class="inline-flex min-h-11 shrink-0 items-center gap-2 self-start rounded-xl bg-slate-800 px-4 py-2 text-sm font-semibold text-slate-300 ring-1 ring-slate-700 sm:self-center">
                    <.icon name="hero-check" class="size-4 text-teal-300" /> In library
                  </span>
                <% true -> %>
                  <button
                    type="button"
                    phx-click="add"
                    phx-value-igdb_id={game["id"]}
                    phx-disable-with="Adding…"
                    class="min-h-11 shrink-0 self-start rounded-xl border border-teal-400/40 px-5 py-2 text-sm font-semibold text-teal-200 transition hover:bg-teal-400/10 disabled:cursor-wait disabled:opacity-60 sm:self-center"
                  >Add</button>
              <% end %>
            </article>
          </div>
        </section>

        <section
          :if={!@replacement}
          id="steam-manual-import"
          class="rounded-3xl border border-slate-800 bg-slate-950/60 p-6"
        >
          <h2 class="text-lg font-semibold text-heading">Add a missing Steam game</h2>
          <p class="mt-1 max-w-3xl text-sm leading-6 text-slate-400">
            Steam can omit unplayed free games from its library API. Paste an AppID or Steam Store URL to keep the game in your selected personal Steam library.
          </p>
          <.form
            for={@steam_form}
            id="steam-manual-import-form"
            phx-submit="add_steam"
            class="mt-4 flex flex-col gap-3 sm:flex-row sm:items-end"
          >
            <div class="min-w-0 flex-1">
              <.input
                field={@steam_form[:app_id]}
                id="steam-manual-app-id"
                type="text"
                inputmode="numeric"
                label="Steam AppID or Store URL"
                placeholder="2771670"
                required
              />
            </div>
            <.button id="add-steam-app" class="shrink-0" phx-disable-with="Checking…">
              Add Steam game
            </.button>
          </.form>
        </section>

        <section :if={!@replacement} class="rounded-3xl border border-slate-800 bg-slate-950/60 p-6">
          <h2 class="text-lg font-semibold text-heading">Batch import IGDB IDs</h2>
          <p class="mt-1 text-sm text-slate-400">
            Paste up to 500 numeric IDs, separated by spaces, commas, or lines.
          </p>
          <.form for={@batch_form} id="igdb-batch-import" phx-submit="batch" class="mt-4 space-y-4">
            <.input field={@batch_form[:ids]} type="textarea" label="IGDB IDs" rows="8" />
            <.button id="import-igdb-ids">Import games</.button>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp release_year(%{"first_release_date" => timestamp}) when is_integer(timestamp) do
    case DateTime.from_unix(timestamp) do
      {:ok, dt} -> dt.year
      _ -> nil
    end
  end

  defp release_year(_), do: nil

  defp developer_names(game) do
    game
    |> Map.get("involved_companies", [])
    |> Enum.filter(&(&1["developer"] == true))
    |> Enum.map(&get_in(&1, ["company", "name"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp result_metadata(game) do
    platforms =
      game
      |> Map.get("platforms", [])
      |> Enum.map(& &1["name"])
      |> Enum.reject(&is_nil/1)
      |> compact_platforms()

    [game_type(game), platforms, "IGDB #{game["id"]}"]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp game_type(%{"game_type" => %{"type" => type}}) when is_binary(type), do: type
  defp game_type(_), do: nil

  defp compact_platforms([]), do: nil

  defp compact_platforms(platforms) do
    shown = platforms |> Enum.take(3) |> Enum.join(", ")
    remaining = length(platforms) - 3

    if remaining > 0, do: "#{shown} +#{remaining}", else: shown
  end

  defp refresh_result_ownership(%{assigns: %{result_lookup: lookup}} = socket)
       when map_size(lookup) == 0,
       do: socket

  defp refresh_result_ownership(socket) do
    {:ok, statuses} =
      Custom.ownership_status(
        socket.assigns.current_scope,
        Map.keys(socket.assigns.result_lookup)
      )

    results =
      Map.new(socket.assigns.result_lookup, fn {id, game} ->
        status = Map.get(statuses, id, %{owned: false, custom_owned: false})

        {id,
         game
         |> Map.put("owned", status.owned)
         |> Map.put("custom_owned", status.custom_owned)}
      end)

    Enum.reduce(results, assign(socket, :result_lookup, results), fn {_id, game}, socket ->
      stream_insert(socket, :results, game)
    end)
  end

  defp batch_message(counts) do
    parts =
      [
        "Added #{counts.added}",
        counts.already_owned > 0 && "#{counts.already_owned} already in your library",
        counts.failed > 0 && "#{counts.failed} not found"
      ]
      |> Enum.filter(&is_binary/1)

    Enum.join(parts, " · ") <> "."
  end

  defp message(:not_configured), do: "IGDB credentials are not configured."
  defp message(:invalid_igdb_id), do: "That IGDB ID is invalid."
  defp message(:same_game), do: "That is already the selected game."
  defp message(:game_not_found), do: "IGDB did not return that game."
  defp message(:invalid_app_id), do: "Enter a numeric Steam AppID or Steam Store URL."

  defp message(:steam_account_required),
    do: "Connect a Steam account and select it as your main account first."

  defp message(:not_a_game), do: "That Steam AppID is not classified as a game."
  defp message(:store_metadata_unavailable), do: "Steam Store did not return that AppID."
  defp message(:no_igdb_ids), do: "No IGDB IDs were found."
  defp message(:too_many_igdb_ids), do: "Import at most 500 games at once."
  defp message(%Iri.Integrations.Error{message: message}), do: message
  defp message(_), do: "The IGDB request could not be completed."

  defp replacement_game(_scope, nil), do: nil

  defp replacement_game(scope, game_id) do
    case Custom.get_replaceable_game(scope, game_id) do
      {:ok, game} -> game
      _error -> nil
    end
  end
end
