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

defmodule IriWeb.Settings.MatchesLive.Presentation do
  @moduledoc "Presentation helpers for the administrator catalog-match queue."

  def reviews_by_source(reviews) do
    Enum.reduce(reviews, %{}, fn review, grouped ->
      Map.put_new(grouped, review.game_source_id, review)
    end)
  end

  def ai_status_label({:ok, config}),
    do: "#{config.provider |> Atom.to_string() |> String.replace("_", " ")} · #{config.mode}"

  def ai_status_label({:disabled, _reason}), do: "Not configured"

  def ai_status_class({:ok, _config}),
    do: "rounded-full bg-emerald-400/10 px-2.5 py-1 text-xs font-semibold text-emerald-200"

  def ai_status_class({:disabled, _reason}),
    do: "rounded-full bg-slate-800 px-2.5 py-1 text-xs font-semibold text-slate-400"

  def ai_mode_description({:ok, %{mode: :auto}}) do
    "Auto mode runs unresolved titles after deterministic metadata enrichment and applies validated catalog matches and clear non-game rejections. Store-only and uncertain decisions remain here for review."
  end

  def ai_mode_description({:ok, %{mode: :review}}) do
    "Review mode runs AI only when you explicitly queue unresolved titles. Recommendations remain here until you approve or dismiss them."
  end

  def ai_mode_description({:disabled, _reason}) do
    "Configure an AI provider to enable optional matching after deterministic metadata enrichment."
  end

  def ai_configuration_message(:disabled), do: "AI matching is disabled."

  def ai_configuration_message(:model_missing),
    do: "Set AI_MATCHING_MODEL to enable AI matching."

  def ai_configuration_message(:api_key_missing),
    do: "Set AI_MATCHING_API_KEY to enable this provider."

  def ai_configuration_message(:base_url_missing),
    do: "Set AI_MATCHING_BASE_URL for the compatible endpoint."

  def ai_configuration_message(:invalid_base_url),
    do: "AI_MATCHING_BASE_URL must be an HTTP or HTTPS URL."

  def ai_configuration_message(:configuration),
    do: "The AI provider configuration is incomplete."

  def ai_configuration_message(_reason),
    do: "AI matching is not available with the current configuration."

  def ai_review_heading(%{status: "queued"}), do: "AI review queued"
  def ai_review_heading(%{status: "retry_wait"}), do: "AI retry scheduled"
  def ai_review_heading(%{status: "running"}), do: "AI review running"
  def ai_review_heading(%{status: "failed"}), do: "AI review failed"
  def ai_review_heading(%{status: "abstained"}), do: "AI abstained"

  def ai_review_heading(review),
    do: "AI recommendation · #{round((review.confidence || 0) * 100)}%"

  def failed_model_output(%{
        status: "failed",
        failure_details: %{"model_output" => output}
      }),
      do: Jason.encode!(output, pretty: true)

  def failed_model_output(%{
        status: "failed",
        failure_details: %{"model_output_text" => output}
      })
      when is_binary(output),
      do: output

  def failed_model_output(_review), do: nil

  def ai_action_label(%{
        action: "match",
        selected_title: title,
        selected_catalog: catalog
      })
      when is_binary(title) and is_binary(catalog),
      do: "Match #{title} on #{String.upcase(catalog)}"

  def ai_action_label(%{action: "match"}), do: "Match the selected catalog candidate"

  def ai_action_label(%{action: "reject"}), do: "Reject as a non-game"
  def ai_action_label(%{action: "keep_store_only"}), do: "Keep as a store-only game"
  def ai_action_label(%{action: "abstain"}), do: "Not enough evidence to decide"
  def ai_action_label(_review), do: "Waiting for a recommendation"

  def ai_approval_confirmation(%{action: "reject"}),
    do: "Reject this source as a non-game? The decision can be reopened from history."

  def ai_approval_confirmation(_review), do: nil

  def candidate_metadata(candidate) do
    [
      candidate_release_year(candidate),
      candidate_game_type(candidate),
      candidate_platforms(candidate),
      "IGDB #{candidate.igdb_id}",
      "#{round(candidate.score * 100)}% match"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  def candidate_developers(%{metadata: metadata}) do
    metadata
    |> Map.get("involved_companies", [])
    |> Enum.filter(&(&1["developer"] == true))
    |> Enum.map(&get_in(&1, ["company", "name"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  def candidate_developers(_candidate), do: ""

  def candidate_summary(%{metadata: %{"summary" => summary}}) when is_binary(summary),
    do: summary

  def candidate_summary(_candidate), do: nil

  def vndb_metadata(candidate) do
    [vndb_year(candidate), vndb_rating(candidate), candidate["id"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  def vndb_developers(candidate) do
    candidate
    |> Map.get("developers", [])
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  def vndb_summary(%{"description" => description}) when is_binary(description),
    do: String.replace(description, ~r/\[\/?\w+(?:=[^\]]+)?\]/u, "")

  def vndb_summary(_candidate), do: nil

  defp candidate_release_year(%{metadata: %{"first_release_date" => timestamp}})
       when is_integer(timestamp) do
    case DateTime.from_unix(timestamp) do
      {:ok, datetime} -> Integer.to_string(datetime.year)
      _error -> nil
    end
  end

  defp candidate_release_year(_candidate), do: nil

  defp candidate_game_type(%{metadata: %{"game_type" => %{"type" => type}}})
       when is_binary(type),
       do: type

  defp candidate_game_type(_candidate), do: nil

  defp candidate_platforms(%{metadata: metadata}) do
    metadata
    |> Map.get("platforms", [])
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.take(3)
    |> Enum.join(", ")
  end

  defp candidate_platforms(_candidate), do: ""

  defp vndb_year(%{"released" => <<year::binary-size(4), _rest::binary>>}), do: year
  defp vndb_year(_candidate), do: nil

  defp vndb_rating(%{"rating" => rating}) when is_number(rating),
    do: "VNDB #{Float.round(rating / 10, 1)}/10"

  defp vndb_rating(_candidate), do: nil
end
