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

defmodule IriWeb.GameLive do
  @moduledoc "Authenticated canonical game detail page and personal-state editor."

  use IriWeb, :live_view

  import IriWeb.GameLive.Presentation
  alias Iri.Collections
  alias Iri.Integrations.Custom
  alias Iri.Integrations.Steam.ManualLibrary
  alias Iri.Library
  alias Iri.Library.Personalization
  alias Iri.Media.Policy
  alias Iri.Matches

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Library.get_game_by_slug(socket.assigns.current_scope, slug) do
      {:ok, game} ->
        preferences = List.first(game.user_states)
        user = socket.assigns.current_scope.user

        {:ok, memberships} =
          Collections.game_collection_memberships(socket.assigns.current_scope, game.id)

        {:ok,
         socket
         |> assign(:page_title, game.title)
         |> assign(:game, game)
         |> assign(:game_state, preferences)
         |> assign(:rating_form, rating_form(preferences))
         |> assign(:note_form, note_form(preferences))
         |> assign(:rating_message, nil)
         |> assign(:note_message, nil)
         |> assign_collection_memberships(memberships)
         |> assign(:cover, cover_asset(game, user))
         |> assign(:screenshots, screenshots(game, user))
         |> assign(:sensitive_media_blurred?, Policy.blurred?(game, user))
         |> assign(:sensitive_media_revealed?, false)
         |> assign(:screenshot_index, nil)
         |> assign(:trailer_index, nil)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "That game is not in the local library.")
         |> push_navigate(to: ~p"/library")}
    end
  end

  @impl true
  def handle_event("show_screenshot", %{"index" => index}, socket) do
    {:noreply,
     assign(
       socket,
       :screenshot_index,
       valid_index(index, length(socket.assigns.screenshots))
     )}
  end

  def handle_event("reveal_sensitive_media", _params, socket) do
    {:noreply,
     socket
     |> assign(:sensitive_media_revealed?, true)
     |> assign(:screenshot_index, nil)}
  end

  def handle_event("mark_game_not_sensitive", _params, socket) do
    case Library.mark_game_not_sensitive(
           socket.assigns.current_scope,
           socket.assigns.game.id
         ) do
      {:ok, _game} ->
        {:noreply,
         socket
         |> reload_game()
         |> put_flash(:info, "This game is no longer marked as sensitive.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update sensitive-media status.")}
    end
  end

  def handle_event("mark_game_sensitive", _params, socket) do
    case Library.mark_game_sensitive(
           socket.assigns.current_scope,
           socket.assigns.game.id
         ) do
      {:ok, _game} ->
        {:noreply,
         socket
         |> reload_game()
         |> put_flash(:info, "This game is now marked as NSFW.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update sensitive-media status.")}
    end
  end

  def handle_event("close_screenshot", _params, socket) do
    {:noreply, assign(socket, :screenshot_index, nil)}
  end

  def handle_event("previous_screenshot", _params, socket) do
    {:noreply, move_screenshot(socket, -1)}
  end

  def handle_event("next_screenshot", _params, socket) do
    {:noreply, move_screenshot(socket, 1)}
  end

  def handle_event("load_trailer", %{"index" => index}, socket) do
    {:noreply,
     assign(socket, :trailer_index, valid_index(index, length(videos(socket.assigns.game))))}
  end

  def handle_event("close_trailer", _params, socket) do
    {:noreply, assign(socket, :trailer_index, nil)}
  end

  def handle_event("set_game_state", %{"state" => state}, socket) do
    selected? = completion_state(socket.assigns.game_state) == state

    result =
      if selected? do
        Library.clear_game_state(socket.assigns.current_scope, socket.assigns.game.id)
      else
        Library.set_game_state(socket.assigns.current_scope, socket.assigns.game.id, state)
      end

    case result do
      {:ok, game_state} ->
        message =
          if selected?,
            do: "Completion status cleared.",
            else: "Game marked #{completion_state_label(state)}."

        {:noreply,
         socket
         |> assign(:game_state, game_state)
         |> put_flash(:info, message)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update that game.")}
    end
  end

  def handle_event("set_rating", %{"rating" => %{"value" => value}}, socket) do
    with {:ok, rating} <- parse_rating(value),
         {:ok, game_state} <-
           Personalization.set_rating(
             socket.assigns.current_scope,
             socket.assigns.game.id,
             rating
           ) do
      {:noreply,
       socket
       |> assign(:game_state, game_state)
       |> assign(:rating_form, rating_form(game_state))
       |> assign(:rating_message, "Rating saved.")}
    else
      _error ->
        {:noreply,
         socket
         |> assign(:rating_form, rating_form(socket.assigns.game_state))
         |> assign(:rating_message, nil)
         |> put_flash(:error, "Could not save your rating.")}
    end
  end

  def handle_event("clear_rating", _params, socket) do
    case Personalization.set_rating(
           socket.assigns.current_scope,
           socket.assigns.game.id,
           nil
         ) do
      {:ok, game_state} ->
        {:noreply,
         socket
         |> assign(:game_state, game_state)
         |> assign(:rating_form, rating_form(game_state))
         |> assign(:rating_message, "Rating cleared.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not clear your rating.")}
    end
  end

  def handle_event("save_note", %{"note" => %{"notes" => note}}, socket) do
    save_personal_note(socket, note)
  end

  def handle_event("save_note", %{"value" => note}, socket) do
    save_personal_note(socket, note)
  end

  def handle_event("save_note", _params, socket), do: {:noreply, socket}

  def handle_event("update_collections", %{"collections" => params}, socket) do
    collection_ids =
      params
      |> Map.get("collection_ids", [])
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))

    case Collections.set_game_collections(
           socket.assigns.current_scope,
           socket.assigns.game.id,
           collection_ids
         ) do
      {:ok, _changes} ->
        {:ok, memberships} =
          Collections.game_collection_memberships(
            socket.assigns.current_scope,
            socket.assigns.game.id
          )

        {:noreply,
         socket
         |> assign_collection_memberships(memberships)
         |> put_flash(:info, "Collections updated.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update collections.")}
    end
  end

  def handle_event("update_collections", _params, socket), do: {:noreply, socket}

  def handle_event("remove_custom_game", _params, socket) do
    case Custom.remove_igdb_id(socket.assigns.current_scope, socket.assigns.game.igdb_id) do
      {:ok, %{removed: removed}} when removed > 0 ->
        case Library.get_game_by_slug(
               socket.assigns.current_scope,
               socket.assigns.game.slug
             ) do
          {:ok, game} ->
            {:noreply,
             socket
             |> assign(:game, game)
             |> put_flash(:info, "Custom game removed from your library.")}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> put_flash(:info, "Custom game removed from your library.")
             |> push_navigate(to: ~p"/library")}
        end

      {:ok, _result} ->
        {:noreply, put_flash(socket, :info, "That custom game is no longer in your library.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove that custom game.")}
    end
  end

  def handle_event("fix_match", _params, socket) do
    scope = socket.assigns.current_scope
    game = socket.assigns.game

    cond do
      scope.role == :admin ->
        case Matches.reopen_game_for_review(scope, game.id) do
          {:ok, source_id} ->
            {:noreply, push_navigate(socket, to: ~p"/settings/matches?source_id=#{source_id}")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not open this game for match review.")}
        end

      # A non-admin owner can still re-point their own custom game.
      custom_owned?(game, scope.user.id) ->
        {:noreply, push_navigate(socket, to: ~p"/library/add?replace=#{game.id}")}

      true ->
        {:noreply, put_flash(socket, :error, "You cannot change this game's match.")}
    end
  end

  def handle_event("remove_manual_steam_game", %{"source_id" => source_id}, socket) do
    case ManualLibrary.remove(socket.assigns.current_scope, source_id) do
      {:ok, %{removed: 1}} ->
        case Library.get_game_by_slug(
               socket.assigns.current_scope,
               socket.assigns.game.slug
             ) do
          {:ok, _game} ->
            {:noreply,
             socket
             |> reload_game()
             |> put_flash(:info, "Manually added Steam game removed.")}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> put_flash(:info, "Manually added Steam game removed.")
             |> push_navigate(to: ~p"/library")}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove that Steam game.")}
    end
  end

  @impl true
  def render(assigns), do: IriWeb.GameLive.Detail.render(assigns)

  defp assign_collection_memberships(socket, memberships) do
    selected_ids =
      memberships
      |> Enum.filter(& &1.member?)
      |> Enum.map(&Integer.to_string(&1.id))

    socket
    |> assign(:collection_memberships, memberships)
    |> assign(
      :collection_form,
      to_form(%{"collection_ids" => selected_ids}, as: :collections)
    )
  end

  defp reload_game(socket) do
    {:ok, game} =
      Library.get_game_by_slug(socket.assigns.current_scope, socket.assigns.game.slug)

    user = socket.assigns.current_scope.user

    socket
    |> assign(:game, game)
    |> assign(:cover, cover_asset(game, user))
    |> assign(:screenshots, screenshots(game, user))
    |> assign(:sensitive_media_blurred?, Policy.blurred?(game, user))
    |> assign(:sensitive_media_revealed?, false)
    |> assign(:screenshot_index, nil)
  end

  defp save_personal_note(socket, note) do
    case Personalization.set_note(
           socket.assigns.current_scope,
           socket.assigns.game.id,
           note
         ) do
      {:ok, game_state} ->
        {:noreply,
         socket
         |> assign(:game_state, game_state)
         |> assign(:note_form, note_form(game_state))
         |> assign(:note_message, "Note saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:note_form, to_form(changeset, as: :note))
         |> assign(:note_message, nil)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not save your note.")}
    end
  end

  defp parse_rating(value) when is_binary(value) do
    case Float.parse(value) do
      {rating, ""} when rating >= 1 and rating <= 5 ->
        if rating * 2 == round(rating * 2),
          do: {:ok, rating},
          else: {:error, :invalid_rating}

      _other ->
        {:error, :invalid_rating}
    end
  end

  defp parse_rating(_value), do: {:error, :invalid_rating}

  defp valid_index(value, count) when count > 0 do
    case Integer.parse(to_string(value)) do
      {index, ""} when index >= 0 and index < count -> index
      _other -> nil
    end
  end

  defp valid_index(_value, _count), do: nil

  defp move_screenshot(%{assigns: %{screenshot_index: nil}} = socket, _direction), do: socket

  defp move_screenshot(socket, direction) do
    count = length(socket.assigns.screenshots)

    assign(
      socket,
      :screenshot_index,
      Integer.mod(socket.assigns.screenshot_index + direction, count)
    )
  end
end
