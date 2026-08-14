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

defmodule Iri.Security.SafeText do
  @moduledoc "Normalizes external or persisted binaries into display-safe UTF-8 text."

  @control_characters ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u
  @omitted "[non-text data omitted]"

  def display(value) when is_binary(value) do
    case :unicode.characters_to_binary(value) do
      text when is_binary(text) -> normalize_controls(text)
      {:error, prefix, _rest} -> append_omitted(prefix)
      {:incomplete, prefix, _rest} -> append_omitted(prefix)
    end
  end

  def display(value), do: value

  defp append_omitted(prefix) do
    case prefix |> normalize_controls() |> String.trim_trailing() do
      "" -> @omitted
      text -> text <> " " <> @omitted
    end
  end

  defp normalize_controls(text), do: Regex.replace(@control_characters, text, " ")
end
