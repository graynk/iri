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

defmodule Iri.AI do
  @moduledoc "Durable, optional AI-assisted catalog matching."

  import Ecto.Query, warn: false

  alias Iri.Accounts.Scope

  alias Iri.AI.{
    CandidateBuilder,
    Config,
    MatchDecision,
    MatchRequest,
    MatchReview,
    Prompt
  }

  alias Iri.AI.ProviderError
  alias Iri.Integrations
  alias Iri.Integrations.IGDB.{Client, Enricher}
  alias Iri.Integrations.VNDB.Client, as: VNDBClient
  alias Iri.Integrations.VNDB.Enricher, as: VNDBEnricher
  alias Iri.Library.{GameSource, Title}
  alias Iri.Matches
  alias Iri.Matches.Decisions
  alias Iri.Repo
  alias Iri.Security.Redactor

  @active_statuses ~w(queued running retry_wait recommended abstained failed)
  @pending_statuses ~w(queued retry_wait)
  @automatic_match_methods ~w(ambiguous unmatched)
  @lease_seconds 180
  @max_attempts 4
  @daily_request_limit 500

  @doc "Returns the validated AI matching configuration derived from the runtime environment."
  def configuration, do: Config.current()

  @doc "Returns a safe-to-display summary of whether optional AI matching is configured."
  def configuration_status do
    config = configuration()

    case Config.enabled(config) do
      {:ok, config} ->
        adapter = Config.adapter(config)

        case adapter.validate_configuration(config) do
          :ok -> {:ok, config}
          {:error, error} -> {:disabled, error.category}
        end

      {:disabled, reason} ->
        {:disabled, reason}
    end
  end

  @doc "Lists persisted AI recommendations visible to an administrator."
  def list_reviews(%Scope{} = scope, options \\ []) do
    with :ok <- authorize_admin(scope) do
      statuses =
        Keyword.get(
          options,
          :statuses,
          ~w(recommended abstained failed running queued retry_wait)
        )

      limit = Keyword.get(options, :limit, 5_000)

      {:ok,
       Repo.all(
         from review in MatchReview,
           where: review.status in ^statuses,
           order_by: [desc: review.updated_at, desc: review.id],
           limit: ^limit,
           preload: [:game_source]
       )}
    end
  end

  @doc "Returns aggregate AI-review queue counts for the administrator interface."
  def summary(%Scope{} = scope) do
    with :ok <- authorize_admin(scope) do
      counts =
        Repo.all(
          from review in MatchReview,
            group_by: review.status,
            select: {review.status, count(review.id)}
        )
        |> Map.new()

      {:ok,
       %{
         queued: Map.get(counts, "queued", 0) + Map.get(counts, "retry_wait", 0),
         running: Map.get(counts, "running", 0),
         review: Map.get(counts, "recommended", 0) + Map.get(counts, "abstained", 0),
         applied: Map.get(counts, "applied", 0),
         failed: Map.get(counts, "failed", 0)
       }}
    end
  end

  @doc "Queues eligible unresolved sources for optional AI-assisted matching."
  def enqueue_unresolved(%Scope{} = scope, options \\ []) do
    with :ok <- authorize_admin(scope),
         {:ok, config} <- enabled_configuration(),
         {:ok, sources} <- Matches.list_queue(scope, queue_options(options)) do
      now = DateTime.utc_now(:second)
      prompt_version = Prompt.version()

      result =
        Enum.reduce(sources, %{queued: 0, existing: 0, failed: 0}, fn source, counts ->
          fingerprint = CandidateBuilder.source_fingerprint(source)

          attrs = %{
            game_source_id: source.id,
            status: "queued",
            model: config.model,
            prompt_version: prompt_version,
            source_fingerprint: fingerprint,
            next_attempt_at: now
          }

          case active_review(source.id) do
            %MatchReview{
              source_fingerprint: ^fingerprint,
              prompt_version: ^prompt_version
            } ->
              %{counts | existing: counts.existing + 1}

            %MatchReview{} = existing ->
              existing
              |> MatchReview.changeset(%{status: "superseded"})
              |> Repo.update!()

              insert_review(attrs, counts)

            nil ->
              insert_review(attrs, counts)
          end
        end)

      if Keyword.get(options, :wake_worker, true), do: wake_worker()
      notify()
      {:ok, result}
    end
  end

  @doc "Queues and processes unresolved sources when AI matching is configured in auto mode."
  def run_automatic(%Scope{} = scope, options \\ []) do
    with :ok <- authorize_admin(scope) do
      case configuration_status() do
        {:ok, %{mode: :auto} = config} ->
          with {:ok, _pruned_count} <- supersede_unready_pending(),
               {:ok, counts} <-
                 enqueue_unresolved(scope,
                   wake_worker: false,
                   ai_ready: true,
                   source_ids: Keyword.get(options, :source_ids)
                 ),
               {:ok, processed_count} <- process_automatic_queue(config, options, 0) do
            {:ok, Map.put(counts, :processed, processed_count)}
          end

        {:ok, %{mode: :review}} ->
          {:ok, automatic_skip(:review)}

        {:disabled, _reason} ->
          {:ok, automatic_skip(:disabled)}
      end
    end
  end

  @doc "Dismisses AI reviews that have not started, leaving completed recommendations untouched."
  def cancel_pending(%Scope{} = scope) do
    with :ok <- authorize_admin(scope) do
      now = DateTime.utc_now(:second)

      result =
        Repo.transact_with_busy_retry(
          fn ->
            {count, _} =
              Repo.update_all(
                from(review in MatchReview, where: review.status in ^@pending_statuses),
                set: [
                  status: "dismissed",
                  reason: "Administrator cleared the pending AI queue.",
                  next_attempt_at: nil,
                  lease_token: nil,
                  lease_expires_at: nil,
                  updated_at: now
                ]
              )

            {:ok, count}
          end,
          mode: :immediate
        )

      notify()
      result
    end
  end

  defp queue_options(options) do
    [
      limit: :all,
      ai_ready: Keyword.get(options, :ai_ready, false),
      source_ids: Keyword.get(options, :source_ids)
    ]
  end

  defp supersede_unready_pending do
    now = DateTime.utc_now(:second)

    review_ids =
      Repo.all(
        from review in MatchReview,
          join: source in assoc(review, :game_source),
          where:
            review.status in ^@pending_statuses and
              (is_nil(source.match_method) or
                 source.match_method not in ^@automatic_match_methods or
                 source.manual_lock or not is_nil(source.game_id)),
          select: review.id
      )

    if review_ids == [] do
      {:ok, 0}
    else
      Repo.transact_with_busy_retry(
        fn ->
          {count, _} =
            Repo.update_all(
              from(review in MatchReview, where: review.id in ^review_ids),
              set: [
                status: "superseded",
                reason:
                  "Superseded because deterministic matching had not left this source unresolved.",
                next_attempt_at: nil,
                lease_token: nil,
                lease_expires_at: nil,
                updated_at: now
              ]
            )

          {:ok, count}
        end,
        mode: :immediate
      )
    end
  end

  @doc "Dismisses an AI recommendation without changing the underlying source match."
  def dismiss(%Scope{} = scope, review_id) do
    with :ok <- authorize_admin(scope),
         %MatchReview{} = review <- Repo.get(MatchReview, review_id),
         true <- review.status in ["recommended", "abstained", "failed"] do
      review
      |> MatchReview.changeset(%{
        status: "dismissed",
        lease_token: nil,
        lease_expires_at: nil
      })
      |> Repo.update()
      |> tap(fn _result -> notify() end)
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_review_state}
      error -> error
    end
  end

  @doc "Applies a previously retained AI recommendation through the audited match workflow."
  def approve(%Scope{} = scope, review_id) do
    with :ok <- authorize_admin(scope),
         %MatchReview{} = review <- Repo.get(MatchReview, review_id),
         true <- review.status in ["recommended", "abstained"],
         {:ok, source} <- apply_review(review, %{type: "admin", user_id: scope.user.id}) do
      notify()
      {:ok, source}
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_review_state}
      error -> error
    end
  end

  @doc "Claims the next eligible AI review and gives it a recoverable worker lease."
  def claim_next(_config, now \\ DateTime.utc_now(:second)) do
    cond do
      queue_paused?() ->
        :none

      requests_today(now) >= @daily_request_limit ->
        :none

      true ->
        Repo.transact(
          fn ->
            review_id =
              Repo.one(
                from review in MatchReview,
                  where:
                    (review.status == "queued" and
                       (is_nil(review.next_attempt_at) or review.next_attempt_at <= ^now)) or
                      (review.status == "retry_wait" and review.next_attempt_at <= ^now) or
                      (review.status == "running" and review.lease_expires_at <= ^now),
                  order_by: [asc: review.next_attempt_at, asc: review.id],
                  limit: 1,
                  select: review.id
              )

            if review_id do
              token = Ecto.UUID.generate()

              {count, _} =
                Repo.update_all(
                  from(review in MatchReview,
                    where:
                      review.id == ^review_id and
                        (review.status in ["queued", "retry_wait"] or
                           (review.status == "running" and review.lease_expires_at <= ^now))
                  ),
                  set: [
                    status: "running",
                    lease_token: token,
                    lease_expires_at: DateTime.add(now, @lease_seconds, :second),
                    updated_at: now
                  ],
                  inc: [attempt_count: 1]
                )

              if count == 1,
                do:
                  record_attempt_and_return(
                    Repo.get_by!(MatchReview, id: review_id, lease_token: token),
                    now
                  ),
                else: {:ok, nil}
            else
              {:ok, nil}
            end
          end,
          mode: :immediate
        )
        |> case do
          {:ok, %MatchReview{} = review} -> {:ok, review}
          _none -> :none
        end
    end
  end

  @doc "Runs one claimed review through the configured provider and persists its result."
  def execute(%MatchReview{} = review, config, options \\ []) do
    with %GameSource{manual_lock: false, game_id: nil} = source <-
           Repo.get(GameSource, review.game_source_id),
         {:ok, request} <- CandidateBuilder.build(source, options),
         adapter = Keyword.get(options, :adapter, Config.adapter(config)),
         {:ok, request, decision} <-
           decide_with_search(review, source, request, adapter, config, options),
         {:ok, review} <- store_recommendation(review, request, decision),
         {:ok, review} <- maybe_auto_apply(review, config) do
      notify()
      {:ok, review}
    else
      nil ->
        supersede(review, "Source no longer exists.")

      %GameSource{} ->
        supersede(review, "Source was resolved while the review was queued.")

      {:error, %ProviderError{} = error} ->
        fail_review(review, error)

      {:error, reason} ->
        fail_review(
          review,
          %ProviderError{
            category: :invalid_response,
            message: "AI review failed before a provider decision: #{safe_reason(reason)}",
            retryable: false
          }
        )
    end
  end

  defp decide_with_search(review, source, request, adapter, config, options) do
    adapter_options = Keyword.get(options, :adapter_options, [])

    with {:ok, decision} <- adapter.decide(request, config, adapter_options) do
      continue_decision(
        review,
        source,
        request,
        decision,
        adapter,
        config,
        adapter_options,
        options
      )
    end
  end

  defp continue_decision(
         review,
         source,
         request,
         %MatchDecision{action: "search", search_query: query} = search_decision,
         adapter,
         config,
         adapter_options,
         builder_options
       ) do
    cond do
      not MatchRequest.search_allowed?(request) ->
        {:error,
         invalid_search_decision(
           search_decision,
           "The AI endpoint requested another catalog search after the search limit was reached."
         )}

      repeated_search?(request, query) ->
        correct_repeated_search(
          review,
          source,
          request,
          search_decision,
          adapter,
          config,
          adapter_options,
          builder_options
        )

      true ->
        with {:ok, expanded_request} <-
               CandidateBuilder.search(source, request, query, builder_options),
             :ok <- reserve_followup_request(review),
             {:ok, next_decision} <- adapter.decide(expanded_request, config, adapter_options),
             {:ok, final_request, final_decision} <-
               continue_decision(
                 review,
                 source,
                 expanded_request,
                 next_decision,
                 adapter,
                 config,
                 adapter_options,
                 builder_options
               ) do
          {:ok, final_request, final_decision}
        end
    end
  end

  defp continue_decision(
         _review,
         _source,
         request,
         %MatchDecision{action: "keep_store_only"} = decision,
         _adapter,
         _config,
         _adapter_options,
         _builder_options
       ) do
    if Enum.any?(request.candidates, &(&1["deterministic_score"] == 1.0)) do
      corrected = %{
        decision
        | action: "abstain",
          candidate_key: nil,
          search_query: nil,
          confidence: min(decision.confidence, 0.5),
          reason:
            "Exact-title catalog candidates remain. Manual review is required instead of " <>
              "keeping this source store-only. Original model reason: #{decision.reason}"
      }

      {:ok, request, corrected}
    else
      {:ok, request, decision}
    end
  end

  defp continue_decision(
         _review,
         _source,
         request,
         decision,
         _adapter,
         _config,
         _adapter_options,
         _builder_options
       ),
       do: {:ok, request, decision}

  defp correct_repeated_search(
         review,
         source,
         request,
         search_decision,
         adapter,
         config,
         adapter_options,
         builder_options
       ) do
    if is_binary(request.search_feedback) do
      {:error,
       invalid_search_decision(
         search_decision,
         "The AI endpoint repeated a catalog search after being asked for a different resolution."
       )}
    else
      feedback =
        "The proposed query #{inspect(search_decision.search_query)} was already executed. " <>
          "Do not repeat or merely repunctuate it. Propose a materially different catalog identity, " <>
          "such as the underlying base game's title."

      corrected_request = %{request | search_feedback: feedback}

      with :ok <- reserve_followup_request(review),
           {:ok, corrected_decision} <-
             adapter.decide(corrected_request, config, adapter_options),
           {:ok, final_request, final_decision} <-
             continue_decision(
               review,
               source,
               corrected_request,
               corrected_decision,
               adapter,
               config,
               adapter_options,
               builder_options
             ) do
        {:ok, final_request, final_decision}
      end
    end
  end

  defp repeated_search?(request, query) do
    normalized_query = Title.normalize(query)
    Enum.any?(request.search_queries, &(Title.normalize(&1) == normalized_query))
  end

  defp invalid_search_decision(decision, message) do
    %ProviderError{
      category: :invalid_response,
      message: message,
      retryable: false,
      details: %{"model_output" => decision.raw || %{}}
    }
  end

  defp store_recommendation(review, request, decision) do
    candidate = Enum.find(request.candidates, &(&1["key"] == decision.candidate_key))
    status = if decision.action == "abstain", do: "abstained", else: "recommended"

    review
    |> MatchReview.changeset(%{
      status: status,
      action: decision.action,
      selected_catalog: candidate && candidate["catalog"],
      selected_external_id: candidate && candidate["external_id"],
      selected_title: candidate && candidate["title"],
      confidence: decision.confidence,
      reason: decision.reason,
      failure_details: %{},
      lease_token: nil,
      lease_expires_at: nil,
      next_attempt_at: nil,
      last_error_category: nil,
      last_error_message: nil
    })
    |> Repo.update()
  end

  defp fail_review(review, error) do
    retry? = error.retryable and review.attempt_count < @max_attempts
    now = DateTime.utc_now(:second)

    attrs = %{
      status: if(retry?, do: "retry_wait", else: "failed"),
      next_attempt_at: if(retry?, do: DateTime.add(now, retry_delay(review, error), :second)),
      lease_token: nil,
      lease_expires_at: nil,
      last_error_category: Atom.to_string(error.category),
      last_error_message: error.message,
      failure_details: error.details || review.failure_details || %{}
    }

    result = review |> MatchReview.changeset(attrs) |> Repo.update()
    notify()
    result
  end

  defp supersede(review, reason) do
    result =
      review
      |> MatchReview.changeset(%{
        status: "superseded",
        reason: reason,
        lease_token: nil,
        lease_expires_at: nil
      })
      |> Repo.update()

    notify()
    result
  end

  defp maybe_auto_apply(%MatchReview{action: action} = review, %{mode: :auto})
       when action in ["match", "reject"] do
    case apply_review(review, %{type: "ai"}) do
      {:ok, _source} -> {:ok, Repo.get!(MatchReview, review.id)}
      {:error, _reason} -> {:ok, review}
    end
  end

  defp maybe_auto_apply(review, _config), do: {:ok, review}

  defp apply_review(%MatchReview{action: "match"} = review, actor) do
    with %GameSource{manual_lock: false} = source <- Repo.get(GameSource, review.game_source_id),
         {:ok, game} <- ingest_selected(review),
         {:ok, {source, _decision}} <-
           Decisions.apply(
             source,
             %{
               action: "match",
               game_id: game.id,
               method: if(actor.type == "ai", do: "ai_auto", else: "ai_approved"),
               confidence: review.confidence,
               selected_catalog: review.selected_catalog,
               selected_external_id: review.selected_external_id,
               reason: review.reason,
               ai_match_review_id: review.id
             },
             actor
           ) do
      {:ok, source}
    else
      nil -> {:error, :not_found}
      %GameSource{} -> {:error, :manual_decision_locked}
      error -> error
    end
  end

  defp apply_review(%MatchReview{action: action} = review, actor)
       when action in ["reject", "keep_store_only"] do
    with %GameSource{manual_lock: false} = source <- Repo.get(GameSource, review.game_source_id),
         {:ok, {source, _decision}} <-
           Decisions.apply(
             source,
             %{
               action: action,
               method: if(action == "reject", do: "ai_rejected", else: "ai_store_only"),
               confidence: review.confidence,
               selected_catalog: if(action == "keep_store_only", do: "store"),
               selected_external_id: if(action == "keep_store_only", do: source.external_id),
               reason: review.reason,
               ai_match_review_id: review.id
             },
             actor
           ) do
      {:ok, source}
    else
      nil -> {:error, :not_found}
      %GameSource{} -> {:error, :manual_decision_locked}
      error -> error
    end
  end

  defp apply_review(%MatchReview{action: "abstain"}, _actor),
    do: {:error, :cannot_apply_abstention}

  defp ingest_selected(%MatchReview{selected_catalog: "igdb", selected_external_id: id}) do
    client = Application.get_env(:iri, :igdb_client, Client)

    with {id, ""} <- Integer.parse(id),
         {:ok, credentials} <- Integrations.igdb_credentials_for_sync(client, []),
         {:ok, [payload]} <- client.games(credentials, [id], []),
         {:ok, game} <- Enricher.ingest_selected_game(payload) do
      {:ok, game}
    else
      _error -> {:error, :candidate_not_found}
    end
  end

  defp ingest_selected(%MatchReview{selected_catalog: "vndb", selected_external_id: id}) do
    client = Application.get_env(:iri, :vndb_client, VNDBClient)

    with {:ok, [payload]} <- client.games([id], []),
         {:ok, game} <- VNDBEnricher.ingest_game(payload) do
      {:ok, game}
    else
      _error -> {:error, :candidate_not_found}
    end
  end

  defp ingest_selected(_review), do: {:error, :candidate_not_found}

  defp enabled_configuration do
    case configuration_status() do
      {:ok, config} -> {:ok, config}
      {:disabled, reason} -> {:error, {:ai_not_configured, reason}}
    end
  end

  defp active_review(source_id) do
    Repo.one(
      from review in MatchReview,
        where: review.game_source_id == ^source_id and review.status in ^@active_statuses,
        order_by: [desc: review.updated_at, desc: review.id],
        limit: 1
    )
  end

  defp insert_review(attrs, counts) do
    case %MatchReview{} |> MatchReview.changeset(attrs) |> Repo.insert() do
      {:ok, _review} -> %{counts | queued: counts.queued + 1}
      {:error, _changeset} -> %{counts | failed: counts.failed + 1}
    end
  end

  defp record_attempt_and_return(review, now) do
    Repo.insert_all("ai_request_attempts", [
      %{ai_match_review_id: review.id, attempted_at: now}
    ])

    {:ok, review}
  end

  defp reserve_followup_request(review) do
    now = DateTime.utc_now(:second)

    if requests_today(now) < @daily_request_limit do
      Repo.insert_all("ai_request_attempts", [
        %{ai_match_review_id: review.id, attempted_at: now}
      ])

      :ok
    else
      tomorrow =
        now |> DateTime.to_date() |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

      {:error,
       %ProviderError{
         category: :rate_limited,
         message: "IRI's daily AI request limit has been reached.",
         retryable: true,
         retry_after_seconds: DateTime.diff(tomorrow, now, :second)
       }}
    end
  end

  defp queue_paused? do
    Repo.exists?(
      from review in MatchReview,
        where:
          review.status == "failed" and
            review.last_error_category in ["authentication", "configuration"]
    )
  end

  defp process_automatic_queue(config, options, processed_count) do
    heartbeat = Keyword.get(options, :heartbeat, fn -> :ok end)
    execute_options = Keyword.delete(options, :heartbeat)

    with :ok <- heartbeat.() do
      case claim_next(config) do
        {:ok, review} ->
          with {:ok, _review} <- execute(review, config, execute_options) do
            process_automatic_queue(config, options, processed_count + 1)
          end

        :none ->
          if running_review?() do
            receive do
            after
              100 -> process_automatic_queue(config, options, processed_count)
            end
          else
            {:ok, processed_count}
          end
      end
    end
  end

  defp running_review? do
    Repo.exists?(from review in MatchReview, where: review.status == "running")
  end

  defp automatic_skip(reason) do
    %{queued: 0, existing: 0, failed: 0, processed: 0, skipped: reason}
  end

  defp requests_today(now) do
    start = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")

    Repo.one(
      from attempt in "ai_request_attempts",
        where: field(attempt, :attempted_at) >= ^start,
        select: count()
    )
  end

  defp retry_delay(_review, %ProviderError{retry_after_seconds: seconds})
       when is_integer(seconds),
       do: min(seconds, 86_400)

  defp retry_delay(review, _error) do
    base = min(round(:math.pow(2, max(review.attempt_count - 1, 0)) * 30), 3_600)
    base + :rand.uniform(max(div(base, 4), 1))
  end

  defp safe_reason(reason), do: reason |> Redactor.redact_inspect() |> String.slice(0, 300)

  defp wake_worker do
    if Process.whereis(Iri.AI.Worker), do: GenServer.cast(Iri.AI.Worker, :wake)
    :ok
  end

  defp notify, do: Phoenix.PubSub.broadcast(Iri.PubSub, "ai:reviews", :reviews_updated)

  defp authorize_admin(%Scope{} = scope) do
    if Scope.admin?(scope), do: :ok, else: {:error, :unauthorized}
  end
end
