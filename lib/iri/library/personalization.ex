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

defmodule Iri.Library.Personalization do
  @moduledoc "Per-user completion state, rating, and notes for accessible games."

  import Ecto.Query, warn: false

  alias Iri.Accounts.Scope
  alias Iri.Library.{Access, Game, UserGameState}
  alias Iri.Params
  alias Iri.Repo

  @completion_states ["backlog", "playing", "completed", "dropped"]

  @doc "Loads the signed-in user's private state for an accessible canonical game."
  def get(%Scope{user: user} = scope, game_id)
      when not is_nil(user) and is_integer(game_id) and game_id > 0 do
    if Access.game?(scope, game_id) do
      {:ok, Repo.get_by(UserGameState, user_id: user.id, game_id: game_id)}
    else
      {:error, :not_found}
    end
  end

  def get(_scope, _game_id), do: {:error, :unauthorized}

  @doc "Sets or clears the signed-in user's completion state for an accessible game."
  def set_completion_state(%Scope{user: user} = scope, game_id, state)
      when not is_nil(user) and state in @completion_states do
    update_field(scope, game_id, :state, state)
  end

  def set_completion_state(%Scope{user: user} = scope, game_id, nil) when not is_nil(user) do
    update_field(scope, game_id, :state, nil)
  end

  def set_completion_state(%Scope{user: nil}, _game_id, _state), do: {:error, :unauthorized}
  def set_completion_state(%Scope{}, _game_id, _state), do: {:error, :invalid_state}
  def set_completion_state(_scope, _game_id, _state), do: {:error, :unauthorized}

  @doc "Sets or clears completion state for a complete, accessible set of game IDs in one transaction."
  def batch_set_completion_state(%Scope{user: user} = scope, game_ids, state)
      when not is_nil(user) and (state in @completion_states or is_nil(state)) do
    game_ids = normalize_game_ids(game_ids)

    if game_ids == [] do
      {:ok, 0}
    else
      Repo.transaction(fn ->
        accessible_ids =
          Repo.all(
            from game in Game,
              where: game.id in ^game_ids and game.id in subquery(Access.game_ids(scope)),
              select: game.id,
              order_by: game.id
          )

        if accessible_ids != game_ids, do: Repo.rollback(:not_found)

        now = DateTime.utc_now(:second)

        if is_nil(state) do
          clear_completion_states(user.id, game_ids, now)
        else
          upsert_completion_states(user.id, game_ids, state, now)
        end

        length(game_ids)
      end)
    end
  end

  def batch_set_completion_state(%Scope{user: nil}, _game_ids, _state),
    do: {:error, :unauthorized}

  def batch_set_completion_state(%Scope{}, _game_ids, _state), do: {:error, :invalid_state}
  def batch_set_completion_state(_scope, _game_ids, _state), do: {:error, :unauthorized}

  @doc "Sets or clears a half-step personal rating from 1 to 5 for an accessible game."
  def set_rating(%Scope{user: user} = scope, game_id, rating)
      when not is_nil(user) and is_number(rating) do
    case normalize_rating(rating) do
      {:ok, normalized_rating} -> update_field(scope, game_id, :rating, normalized_rating)
      :error -> {:error, :invalid_rating}
    end
  end

  def set_rating(%Scope{user: user} = scope, game_id, nil) when not is_nil(user) do
    update_field(scope, game_id, :rating, nil)
  end

  def set_rating(%Scope{user: nil}, _game_id, _rating), do: {:error, :unauthorized}
  def set_rating(%Scope{}, _game_id, _rating), do: {:error, :invalid_rating}
  def set_rating(_scope, _game_id, _rating), do: {:error, :unauthorized}

  @doc "Sets or clears the signed-in user's private note for an accessible game."
  def set_note(%Scope{user: user} = scope, game_id, note)
      when not is_nil(user) and (is_binary(note) or is_nil(note)) do
    note = normalize_note(note)
    update_field(scope, game_id, :notes, note)
  end

  def set_note(%Scope{user: nil}, _game_id, _note), do: {:error, :unauthorized}
  def set_note(%Scope{}, _game_id, _note), do: {:error, :invalid_note}
  def set_note(_scope, _game_id, _note), do: {:error, :unauthorized}

  @doc "Returns a note changeset for existing or not-yet-created personal state."
  def change_note(preferences, attrs \\ %{})

  def change_note(%UserGameState{} = preferences, attrs) do
    UserGameState.note_changeset(preferences, attrs)
  end

  def change_note(nil, attrs), do: UserGameState.note_changeset(%UserGameState{}, attrs)

  defp update_field(%Scope{user: user} = scope, game_id, field, value)
       when is_integer(game_id) and game_id > 0 do
    if Access.game?(scope, game_id) do
      case Repo.get_by(UserGameState, user_id: user.id, game_id: game_id) do
        nil when is_nil(value) ->
          {:ok, nil}

        preferences ->
          preferences = preferences || %UserGameState{user_id: user.id, game_id: game_id}

          preferences
          |> UserGameState.changeset(%{field => value})
          |> Repo.insert_or_update()
          |> maybe_prune_empty()
      end
    else
      {:error, :not_found}
    end
  end

  defp update_field(_scope, _game_id, _field, _value), do: {:error, :not_found}

  defp upsert_completion_states(user_id, game_ids, state, now) do
    rows =
      Enum.map(game_ids, fn game_id ->
        %{
          user_id: user_id,
          game_id: game_id,
          state: state,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(UserGameState, rows,
      on_conflict: [set: [state: state, updated_at: now]],
      conflict_target: [:user_id, :game_id]
    )
  end

  defp clear_completion_states(user_id, game_ids, now) do
    from(state in UserGameState,
      where: state.user_id == ^user_id and state.game_id in ^game_ids
    )
    |> Repo.update_all(set: [state: nil, updated_at: now])

    from(state in UserGameState,
      where:
        state.user_id == ^user_id and state.game_id in ^game_ids and is_nil(state.state) and
          is_nil(state.rating) and fragment("trim(coalesce(?, '')) = ''", state.notes)
    )
    |> Repo.delete_all()
  end

  defp maybe_prune_empty({:ok, %UserGameState{} = preferences}) do
    if empty?(preferences) do
      case Repo.delete(preferences) do
        {:ok, _preferences} -> {:ok, nil}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:ok, preferences}
    end
  end

  defp maybe_prune_empty(result), do: result

  defp empty?(preferences) do
    is_nil(preferences.state) and is_nil(preferences.rating) and
      blank?(preferences.notes)
  end

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(value) == ""

  defp normalize_note(nil), do: nil

  defp normalize_note(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_rating(rating) do
    half_steps = round(rating * 2)

    if half_steps in 2..10 and abs(rating * 2 - half_steps) < 0.000_001 do
      {:ok, half_steps / 2}
    else
      :error
    end
  end

  defp normalize_game_ids(game_ids) do
    game_ids
    |> List.wrap()
    |> Enum.map(&Params.positive_integer/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
