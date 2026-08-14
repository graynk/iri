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

defmodule Iri.Matches.Decisions do
  @moduledoc "Applies reversible canonical match decisions and records their audit trail."

  import Kernel, except: [apply: 3]
  import Ecto.Query, warn: false

  alias Iri.AI.MatchReview
  alias Iri.Library.{GameSource, LibraryItem, MatchCandidate}
  alias Iri.Matches.MatchDecision
  alias Iri.Repo

  def apply(%GameSource{} = source, attrs, actor) when is_map(attrs) and is_map(actor) do
    Repo.transact_with_busy_retry(
      fn ->
        source = Repo.get!(GameSource, source.id)

        with {:ok, source} <- update_source(source, attrs),
             :ok <- maybe_restore_historical_items(source, attrs),
             {_, _} <-
               Repo.delete_all(
                 from candidate in MatchCandidate,
                   where: candidate.game_source_id == ^source.id
               ),
             {:ok, decision} <-
               insert_decision(source, attrs, actor),
             :ok <- mark_review_applied(attrs) do
          {:ok, {source, decision}}
        end
      end,
      mode: :immediate
    )
  end

  def list_history(limit \\ 5_000) do
    Repo.all(
      from decision in MatchDecision,
        order_by: [desc: decision.inserted_at, desc: decision.id],
        limit: ^limit,
        preload: [game_source: :game, admin_user: [], ai_match_review: []]
    )
  end

  def reopen(%GameSource{} = source, actor) do
    apply(
      source,
      %{
        action: "reopen",
        game_id: nil,
        method: nil,
        confidence: nil,
        manual_lock: false,
        catalog_kind: reopened_catalog_kind(source),
        reason: "Decision reopened for review"
      },
      actor
    )
  end

  defp update_source(source, %{action: "match", game_id: game_id} = attrs)
       when is_integer(game_id) do
    source
    |> GameSource.changeset(%{
      game_id: game_id,
      match_method: Map.get(attrs, :method, "manual"),
      manual_lock: Map.get(attrs, :manual_lock, true),
      catalog_kind: normalized_catalog_kind(source.catalog_kind)
    })
    |> Repo.update()
  end

  defp update_source(source, %{action: "keep_store_only"} = attrs) do
    source
    |> GameSource.changeset(%{
      game_id: nil,
      match_method: Map.get(attrs, :method, "ignored"),
      manual_lock: Map.get(attrs, :manual_lock, true),
      catalog_kind: normalized_catalog_kind(source.catalog_kind)
    })
    |> Repo.update()
  end

  defp update_source(source, %{action: "reject"} = attrs) do
    source
    |> GameSource.changeset(%{
      game_id: nil,
      match_method: Map.get(attrs, :method, "rejected"),
      manual_lock: Map.get(attrs, :manual_lock, true),
      catalog_kind: "rejected"
    })
    |> Repo.update()
  end

  defp update_source(source, %{action: "reopen"} = attrs) do
    source
    |> GameSource.changeset(%{
      game_id: attrs[:game_id],
      match_method: attrs[:method],
      manual_lock: false,
      catalog_kind: attrs[:catalog_kind]
    })
    |> Repo.update()
  end

  defp update_source(_source, _attrs), do: {:error, :invalid_decision}

  defp insert_decision(source, attrs, actor) do
    decision_attrs = %{
      game_source_id: source.id,
      ai_match_review_id: attrs[:ai_match_review_id],
      actor_type: Map.fetch!(actor, :type),
      admin_user_id: actor[:user_id],
      action: attrs.action,
      selected_catalog: attrs[:selected_catalog],
      selected_external_id: attrs[:selected_external_id] && to_string(attrs.selected_external_id),
      reason: attrs[:reason],
      confidence: attrs[:confidence]
    }

    %MatchDecision{}
    |> MatchDecision.changeset(decision_attrs)
    |> Repo.insert()
  end

  defp mark_review_applied(%{ai_match_review_id: review_id})
       when is_integer(review_id) do
    case Repo.get(MatchReview, review_id) do
      nil ->
        {:error, :review_not_found}

      review ->
        review
        |> MatchReview.changeset(%{
          status: "applied",
          lease_token: nil,
          lease_expires_at: nil
        })
        |> Repo.update()
        |> case do
          {:ok, _review} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp mark_review_applied(_attrs), do: :ok

  defp maybe_restore_historical_items(source, %{action: "reopen"}) do
    now = DateTime.utc_now(:second)

    Repo.update_all(
      from(item in LibraryItem,
        where: item.game_source_id == ^source.id and item.hidden and not is_nil(item.removed_at)
      ),
      set: [hidden: false, removed_at: nil, updated_at: now]
    )

    :ok
  end

  defp maybe_restore_historical_items(_source, _attrs), do: :ok

  defp reopened_catalog_kind(%GameSource{catalog_kind: "rejected"}), do: "unknown"
  defp reopened_catalog_kind(%GameSource{catalog_kind: kind}), do: kind

  defp normalized_catalog_kind(kind) when kind in [nil, "unknown", "rejected"], do: "game"
  defp normalized_catalog_kind(kind), do: kind
end
