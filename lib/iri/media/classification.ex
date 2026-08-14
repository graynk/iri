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

defmodule Iri.Media.Classification do
  @moduledoc "Persistent automatic and manual sensitive-media classification."

  import Ecto.Query, warn: false

  alias Iri.Library.{Game, GameSource}
  alias Iri.Repo

  @strong_terms ["adult", "adult only", "erotic", "hentai", "sexually explicit"]

  def strong_term?(name) when is_binary(name) do
    name |> String.trim() |> String.downcase() |> then(&(&1 in @strong_terms))
  end

  def strong_term?(_name), do: false

  def manually_not_sensitive?(%{nsfw_override: false}), do: true

  def manually_not_sensitive?(_game), do: false

  def manually_sensitive?(%{nsfw_override: true}), do: true

  def manually_sensitive?(_game), do: false

  def manually_classified?(game),
    do: manually_sensitive?(game) or manually_not_sensitive?(game)

  def set_not_sensitive(game_id) when is_integer(game_id) do
    update_override(game_id, false)
  end

  def set_sensitive(game_id) when is_integer(game_id) do
    update_override(game_id, true)
  end

  def recompute_game(game_id) when is_integer(game_id) do
    case Repo.get(Game, game_id) do
      nil -> {:error, :not_found}
      game -> recompute(game)
    end
  end

  def recompute_game(_game_id), do: {:error, :not_found}

  defp update_override(game_id, value) do
    Repo.transact(fn ->
      case Repo.get(Game, game_id) do
        nil ->
          {:error, :not_found}

        game ->
          with {:ok, game} <- game |> Game.changeset(%{nsfw_override: value}) |> Repo.update() do
            recompute(game)
          end
      end
    end)
  end

  defp recompute(game) do
    sensitive? =
      cond do
        manually_not_sensitive?(game) -> false
        manually_sensitive?(game) -> true
        true -> automatic_sensitive?(game.id)
      end

    if game.nsfw == sensitive? do
      {:ok, game}
    else
      game
      |> Game.changeset(%{nsfw: sensitive?})
      |> Repo.update()
    end
  end

  defp automatic_sensitive?(game_id) do
    Repo.exists?(from source in GameSource, where: source.game_id == ^game_id and source.nsfw) or
      Repo.exists?(
        from term in "taxonomy_terms",
          join: game_term in "game_terms",
          on: field(game_term, :taxonomy_term_id) == field(term, :id),
          where:
            field(game_term, :game_id) == ^game_id and
              fragment("lower(trim(?))", field(term, :name)) in ^@strong_terms
      )
  end
end
