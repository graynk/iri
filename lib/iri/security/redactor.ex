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

defmodule Iri.Security.Redactor do
  @moduledoc "Redacts credentials before exception details are persisted or shown."

  @query_secret ~r/([?&][^=&\s]*(?:password|token|code|secret|api(?:_|-)?key|key|credential|authorization)[^=&\s]*=)[^&\s]+/i

  @assignment_secret ~r/((?:"|')?[^\s=>,:]*(?:password|token|code|secret|api(?:_|-)?key|key|credential|authorization)[^\s=>,:]*(?:"|')?\s*(?:=>|:|=)\s*(?:"|')?)(?:Bearer\s+)?[^,\s"'&}\]]+/i

  @bearer_token ~r/(Bearer\s+)[A-Za-z0-9._~+\/=:-]+/i

  def redact(value) when is_binary(value) do
    value
    |> then(&Regex.replace(@query_secret, &1, fn _match, prefix -> prefix <> "[REDACTED]" end))
    |> then(
      &Regex.replace(@assignment_secret, &1, fn _match, prefix -> prefix <> "[REDACTED]" end)
    )
    |> then(&Regex.replace(@bearer_token, &1, fn _match, prefix -> prefix <> "[REDACTED]" end))
  end

  def redact(value), do: redact_inspect(value)

  def redact_inspect(value) do
    value
    |> Kernel.inspect(limit: 50, printable_limit: 1_000)
    |> redact()
  end

  def exception_message(%{__exception__: true} = exception) do
    exception
    |> Exception.message()
    |> redact()
  end
end
