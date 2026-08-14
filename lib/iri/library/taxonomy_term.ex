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

defmodule Iri.Library.TaxonomyTerm do
  @moduledoc "A provider taxonomy label and the normalization rules used when it is presented."

  use Ecto.Schema
  import Ecto.Changeset

  alias Iri.Library.{Game, Title}

  @igdb_theme_genre_overrides ["38", "41"]
  @display_acronyms %{
    "2d" => "2D",
    "3d" => "3D",
    "4x" => "4X",
    "adv" => "ADV",
    "ai" => "AI",
    "cg" => "CG",
    "cgi" => "CGI",
    "crpg" => "CRPG",
    "fps" => "FPS",
    "jrpg" => "JRPG",
    "lgbtq+" => "LGBTQ+",
    "mmo" => "MMO",
    "mmorpg" => "MMORPG",
    "npc" => "NPC",
    "pve" => "PvE",
    "pvp" => "PvP",
    "rpg" => "RPG",
    "tps" => "TPS",
    "trpg" => "TRPG",
    "vr" => "VR",
    "wwi" => "WWI",
    "wwii" => "WWII"
  }
  @display_acronym_pattern Regex.compile!(
                             "(?<![\\p{L}\\p{N}])(?:#{@display_acronyms |> Map.keys() |> Enum.map_join("|", &Regex.escape/1)})(?![\\p{L}\\p{N}])",
                             "iu"
                           )

  schema "taxonomy_terms" do
    field :source, :string
    field :external_id, :string
    field :kind, :string
    field :name, :string
    field :slug, :string

    many_to_many :games, Game, join_through: "game_terms"
    timestamps(type: :utc_datetime)
  end

  def changeset(term, attrs) do
    term
    |> cast(attrs, [:source, :external_id, :kind, :name, :slug])
    |> validate_required([:source, :external_id, :kind, :name, :slug])
    |> unique_constraint([:source, :kind, :external_id])
  end

  @doc "Returns the locally curated taxonomy kind used by the browsing UI."
  def presentation_kind(%__MODULE__{
        source: "igdb",
        kind: "theme",
        external_id: external_id
      })
      when external_id in @igdb_theme_genre_overrides,
      do: "genre"

  def presentation_kind(%__MODULE__{kind: kind}), do: kind

  def normalized_name(%__MODULE__{name: name}), do: normalized_name(name)
  def normalized_name(name) when is_binary(name), do: Title.normalize(name)
  def normalized_name(_name), do: ""

  @doc "Returns consistent sentence casing for taxonomy labels shown as tags."
  def display_name(%__MODULE__{name: name}), do: display_name(name)

  def display_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.capitalize()
    |> restore_acronyms()
  end

  def display_name(_name), do: ""

  @doc "Collapses provider terms that differ only in casing or punctuation for presentation."
  def deduplicate(terms) when is_list(terms) do
    terms
    |> Enum.group_by(&{presentation_kind(&1), normalized_name(&1)})
    |> Enum.map(fn {_key, equivalents} -> preferred(equivalents) end)
    |> Enum.sort_by(&{presentation_kind(&1), normalized_name(&1), &1.id})
  end

  @doc "Uses the best available casing while retaining each term's original identity."
  def canonicalize_names(terms, pool) when is_list(terms) and is_list(pool) do
    names =
      pool
      |> Enum.group_by(&{presentation_kind(&1), normalized_name(&1)})
      |> Map.new(fn {key, equivalents} -> {key, preferred(equivalents).name} end)

    Enum.map(terms, fn term ->
      %{term | name: Map.get(names, {presentation_kind(term), normalized_name(term)}, term.name)}
    end)
  end

  defp preferred(terms) do
    Enum.max_by(terms, fn term ->
      {case_quality(term.name), source_priority(term.source), -term.id}
    end)
  end

  defp case_quality(name) do
    has_upper? = String.match?(name, ~r/\p{Lu}/u)
    has_lower? = String.match?(name, ~r/\p{Ll}/u)

    cond do
      has_upper? and has_lower? -> 3
      has_upper? -> 2
      true -> 1
    end
  end

  defp source_priority("igdb"), do: 2
  defp source_priority("vndb"), do: 1
  defp source_priority(_source), do: 0

  defp restore_acronyms(name) do
    Regex.replace(@display_acronym_pattern, name, fn match ->
      Map.fetch!(@display_acronyms, String.downcase(match))
    end)
  end
end
