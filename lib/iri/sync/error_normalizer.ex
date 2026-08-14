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

defmodule Iri.Sync.ErrorNormalizer do
  @moduledoc "Converts provider-specific sync failures into safe, user-facing diagnostics."

  alias Iri.Integrations.Error
  alias Iri.Security.Redactor

  def compatibility(%{__exception__: true} = exception),
    do: exception |> Redactor.exception_message() |> String.slice(0, 500)

  def compatibility(reason),
    do: reason |> Redactor.redact_inspect() |> String.slice(0, 500)

  def steam(%Error{} = error), do: error

  def steam(:library_not_visible) do
    %Error{
      kind: :library_not_visible,
      message: "Steam returned no games. Profile and Game Details must both be public.",
      retryable: false,
      provider: :steam
    }
  end

  def steam(:not_configured) do
    %Error{
      kind: :authentication,
      message: "The Steam Web API key is not configured.",
      retryable: false,
      provider: :steam
    }
  end

  def steam(reason) when is_atom(reason) do
    %Error{
      kind: reason,
      message: "Steam sync failed while validating the returned library.",
      retryable: false,
      provider: :steam
    }
  end

  def steam(exception) do
    %Error{
      kind: :unexpected,
      message: exception |> Redactor.exception_message() |> String.slice(0, 500),
      retryable: true,
      provider: :steam
    }
  end

  def gog(%Error{} = error), do: error

  def gog(:not_configured) do
    %Error{
      kind: :authentication,
      message: "The GOG login has expired or is not configured.",
      retryable: false,
      provider: :gog
    }
  end

  def gog(:invalid_page_count) do
    %Error{
      kind: :invalid_page_count,
      message: "GOG returned invalid pagination metadata.",
      retryable: false,
      provider: :gog
    }
  end

  def gog(reason) when is_atom(reason) do
    %Error{
      kind: reason,
      message: "GOG sync failed while validating the returned library.",
      retryable: false,
      provider: :gog
    }
  end

  def gog(exception) do
    %Error{
      kind: :unexpected,
      message: exception |> Redactor.exception_message() |> String.slice(0, 500),
      retryable: true,
      provider: :gog
    }
  end

  def xbox(%Error{} = error), do: error

  def xbox(:not_configured) do
    %Error{
      kind: :authentication,
      message: "The OpenXBL API key is not configured.",
      retryable: false,
      provider: :xbox
    }
  end

  def xbox(:invalid_provider_credential) do
    %Error{
      kind: :authentication,
      message: "Reconnect this Xbox account before syncing it again.",
      retryable: false,
      provider: :xbox
    }
  end

  def xbox(reason) do
    %Error{
      kind: :unexpected,
      message: reason |> Redactor.redact_inspect() |> String.slice(0, 500),
      retryable: true,
      provider: :xbox
    }
  end

  def igdb(%Error{} = error), do: error

  def igdb(:not_configured) do
    %Error{
      kind: :authentication,
      message: "IGDB credentials are not configured.",
      retryable: false,
      provider: :igdb
    }
  end

  def igdb(reason) when is_atom(reason) do
    %Error{
      kind: reason,
      message: "IGDB enrichment could not complete.",
      retryable: false,
      provider: :igdb
    }
  end

  def igdb(%Ecto.InvalidChangesetError{changeset: changeset}) do
    fields =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, _options} -> message end)
      |> Enum.map_join(", ", fn {field, messages} ->
        "#{field} #{Enum.join(messages, ", ")}"
      end)

    %Error{
      kind: :invalid_metadata,
      message: "IGDB metadata could not be stored: #{fields}",
      retryable: false,
      provider: :igdb
    }
  end

  def igdb(exception) do
    %Error{
      kind: :unexpected,
      message: exception |> Redactor.exception_message() |> String.slice(0, 500),
      retryable: true,
      provider: :igdb
    }
  end
end
