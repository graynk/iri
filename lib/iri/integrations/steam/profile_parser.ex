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

defmodule Iri.Integrations.Steam.ProfileParser do
  @moduledoc "Parses supported SteamID64, vanity-name, and profile URL inputs."

  @steamid ~r/^\d{17}$/
  @vanity ~r/^[A-Za-z0-9_-]{1,64}$/

  def parse(input) when is_binary(input) do
    input = String.trim(input)

    cond do
      Regex.match?(@steamid, input) -> {:ok, {:steamid, input}}
      String.starts_with?(input, ["http://", "https://"]) -> parse_url(input)
      Regex.match?(@vanity, input) -> {:ok, {:vanity, input}}
      true -> {:error, :invalid_profile}
    end
  end

  def parse(_input), do: {:error, :invalid_profile}

  defp parse_url(input) do
    uri = URI.parse(input)
    host = uri.host && String.downcase(uri.host)
    segments = String.split(uri.path || "", "/", trim: true)

    if uri.scheme in ["http", "https"] and
         host in ["steamcommunity.com", "www.steamcommunity.com"] do
      parse_segments(segments)
    else
      {:error, :invalid_profile_host}
    end
  end

  defp parse_segments(["profiles", steamid]) do
    if Regex.match?(@steamid, steamid),
      do: {:ok, {:steamid, steamid}},
      else: {:error, :invalid_steamid}
  end

  defp parse_segments(["id", vanity]) do
    if Regex.match?(@vanity, vanity),
      do: {:ok, {:vanity, vanity}},
      else: {:error, :invalid_vanity}
  end

  defp parse_segments(_segments), do: {:error, :invalid_profile_path}
end
