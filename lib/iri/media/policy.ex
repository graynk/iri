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

defmodule Iri.Media.Policy do
  @moduledoc "Presentation policy for media belonging to games marked as NSFW."

  alias Iri.Accounts.{Scope, User}
  alias Iri.Media.Classification

  def default_mode, do: Application.get_env(:iri, :nsfw_media, :blur)

  def mode(%Scope{user: user}), do: mode(user)
  def mode(%User{sensitive_media_mode: :inherit}), do: default_mode()
  def mode(%User{sensitive_media_mode: mode}) when mode in [:blur, :hide, :allow], do: mode
  def mode(_viewer), do: default_mode()

  def restricted?(game, viewer \\ nil), do: nsfw?(game) and mode(viewer) in [:blur, :hide]

  def hidden?(game, viewer \\ nil), do: nsfw?(game) and mode(viewer) == :hide

  def blurred?(game, viewer \\ nil), do: nsfw?(game) and mode(viewer) == :blur

  def image_class(game, viewer \\ nil) do
    if blurred?(game, viewer), do: "sensitive-media-blur", else: nil
  end

  def sensitive?(game), do: nsfw?(game)

  defp nsfw?(game) when is_map(game) do
    cond do
      Classification.manually_not_sensitive?(game) ->
        false

      Classification.manually_sensitive?(game) ->
        true

      true ->
        Map.get(game, :nsfw) == true or
          nsfw_terms?(Map.get(game, :terms)) or
          nsfw_sources?(Map.get(game, :sources))
    end
  end

  defp nsfw?(_game), do: false

  defp nsfw_terms?(terms) when is_list(terms) do
    Enum.any?(terms, fn term ->
      name = if is_map(term), do: Map.get(term, :name) || Map.get(term, "name")
      Classification.strong_term?(to_string(name))
    end)
  end

  defp nsfw_terms?(_terms), do: false

  defp nsfw_sources?(sources) when is_list(sources),
    do: Enum.any?(sources, &(Map.get(&1, :nsfw) == true))

  defp nsfw_sources?(_sources), do: false
end
