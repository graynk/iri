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

defmodule Iri.AITest do
  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Accounts.Scope
  alias Iri.AI
  alias Iri.AI.{AdapterStub, Config, MatchReview, Worker}
  alias Iri.Integrations.ProviderAccount
  alias Iri.Integrations.Steam.Reconciler
  alias Iri.Library.GameSource
  alias Iri.Matches.MatchDecision, as: AuditDecision

  setup do
    previous = Application.get_env(:iri, :ai_matching)

    Application.put_env(:iri, :ai_matching, %{
      provider: :openai_compatible,
      model: "fixture-model",
      base_url: "http://localhost:11434/v1",
      mode: :review
    })

    on_exit(fn -> Application.put_env(:iri, :ai_matching, previous) end)
    :ok
  end

  test "queues idempotently, leases durably, and stores a recommendation" do
    {scope, source} = unresolved_source("AI Fixture")

    assert {:ok, %{queued: 1, existing: 0}} = AI.enqueue_unresolved(scope)
    assert {:ok, %{queued: 0, existing: 1}} = AI.enqueue_unresolved(scope)

    config = Config.current()
    assert {:ok, review} = AI.claim_next(config)
    assert review.game_source_id == source.id
    assert review.status == "running"
    assert review.attempt_count == 1
    assert :none = AI.claim_next(config)

    assert {:ok, recommended} = AI.execute(review, config, adapter: AdapterStub)
    assert recommended.status == "recommended"
    assert recommended.action == "match"
    assert recommended.selected_catalog == "igdb"
    assert is_binary(recommended.selected_title)
  end

  test "an administrator can clear AI work that has not started" do
    {scope, _source} = unresolved_source("Queue Fixture One", 831)
    {_scope, _source} = unresolved_source("Queue Fixture Two", 832, scope.user)

    assert {:ok, %{queued: 2}} = AI.enqueue_unresolved(scope)
    assert {:ok, 2} = AI.cancel_pending(scope)

    assert Repo.all(from review in MatchReview, select: review.status) == [
             "dismissed",
             "dismissed"
           ]

    assert {:ok, summary} = AI.summary(scope)
    assert summary.queued == 0
  end

  test "the AI worker does not resume a persisted queue on application start" do
    {scope, _source} = unresolved_source("Persisted Queue Fixture", 833)
    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(scope)

    worker = start_supervised!({Worker, tick_ms: 10})
    assert :sys.get_state(worker).timer == nil
    assert Repo.one!(MatchReview).status == "queued"
  end

  test "an administrator can approve and audit an AI recommendation" do
    {scope, source} = unresolved_source("Approved Fixture")
    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(scope)
    config = Config.current()
    assert {:ok, review} = AI.claim_next(config)
    assert {:ok, review} = AI.execute(review, config, adapter: AdapterStub)

    assert {:ok, matched} = AI.approve(scope, review.id)
    assert matched.id == source.id
    assert matched.manual_lock
    assert matched.game_id

    review = Repo.get!(MatchReview, review.id)
    assert review.status == "applied"

    audit = Repo.one!(AuditDecision)
    assert audit.actor_type == "admin"
    assert audit.ai_match_review_id == review.id
    assert audit.action == "match"
  end

  test "auto mode applies a validated match without administrator approval" do
    {scope, source} = unresolved_source("Automatic Fixture")
    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(scope)
    config = %{Config.current() | mode: :auto}
    assert {:ok, review} = AI.claim_next(config)

    assert {:ok, %MatchReview{status: "applied"} = applied} =
             AI.execute(review, config,
               adapter: AdapterStub,
               adapter_options: [confidence: 0.25]
             )

    matched = Repo.get!(GameSource, source.id)
    assert matched.manual_lock
    assert matched.game_id
    assert matched.match_method == "ai_auto"

    audit = Repo.one!(AuditDecision)
    assert audit.actor_type == "ai"
    assert audit.ai_match_review_id == applied.id
  end

  test "auto mode queues and processes unresolved sources without a manual wake" do
    {scope, source} = unresolved_source("Automatic Queue Fixture", 834)

    mark_deterministically_unresolved(source)

    Application.put_env(:iri, :ai_matching, %{
      provider: :openai_compatible,
      model: "fixture-model",
      base_url: "http://localhost:11434/v1",
      mode: :auto
    })

    assert {:ok, %{queued: 1, processed: 1}} =
             AI.run_automatic(scope, adapter: AdapterStub, source_ids: [source.id])

    assert %MatchReview{status: "applied"} = Repo.one!(MatchReview)
    assert Repo.get!(GameSource, source.id).match_method == "ai_auto"
  end

  test "automatic matching ignores sources outside the completed deterministic snapshot" do
    {scope, examined} = unresolved_source("Examined Fixture", 835)
    {_scope, late_import} = unresolved_source("Late Import Fixture", 836, scope.user)

    mark_deterministically_unresolved(examined)

    Application.put_env(:iri, :ai_matching, %{
      provider: :openai_compatible,
      model: "fixture-model",
      base_url: "http://localhost:11434/v1",
      mode: :auto
    })

    assert {:ok, %{queued: 1, processed: 1}} =
             AI.run_automatic(scope, adapter: AdapterStub, source_ids: [examined.id])

    assert Repo.get!(GameSource, examined.id).match_method == "ai_auto"
    assert Repo.get!(GameSource, late_import.id).match_method == nil
    refute Repo.get_by(MatchReview, game_source_id: late_import.id)
  end

  test "automatic matching supersedes jobs queued before deterministic matching" do
    {scope, source} = unresolved_source("Premature Queue Fixture", 837)

    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(scope)

    Application.put_env(:iri, :ai_matching, %{
      provider: :openai_compatible,
      model: "fixture-model",
      base_url: "http://localhost:11434/v1",
      mode: :auto
    })

    assert {:ok, %{queued: 0, processed: 0}} =
             AI.run_automatic(scope, adapter: AdapterStub, source_ids: [])

    assert %MatchReview{status: "superseded"} =
             Repo.get_by!(MatchReview, game_source_id: source.id)
  end

  test "a model can correct the catalog search before making its final decision" do
    {scope, _source} = unresolved_source("Borderlands 2 RU", 217_490)
    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(scope)

    config = Config.current()
    assert {:ok, review} = AI.claim_next(config)

    assert {:ok, recommended} =
             AI.execute(review, config,
               adapter: AdapterStub,
               adapter_options: [search_query: "Borderlands 2"]
             )

    assert recommended.status == "recommended"
    assert recommended.action == "match"
    assert recommended.selected_title == "Borderlands 2"

    assert Repo.aggregate("ai_request_attempts", :count) == 2
  end

  test "a model can broaden an unsuccessful corrected search once" do
    {scope, _source} = unresolved_source("Divinity II - The Dragon Knight Saga", 58_540)
    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(scope)

    config = Config.current()
    assert {:ok, review} = AI.claim_next(config)

    assert {:ok, recommended} =
             AI.execute(review, config,
               adapter: AdapterStub,
               adapter_options: [
                 search_queries: ["Divinity II: The Dragon Knight Saga", "Divinity II"]
               ]
             )

    assert recommended.status == "recommended"
    assert is_binary(recommended.selected_title)
    assert Repo.aggregate("ai_request_attempts", :count) == 3
  end

  test "a repeated resolution is corrected without consuming a search slot" do
    {scope, _source} = unresolved_source("Divinity II - The Dragon Knight Saga", 58_541)
    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(scope)

    config = Config.current()
    assert {:ok, review} = AI.claim_next(config)

    assert {:ok, recommended} =
             AI.execute(review, config,
               adapter: AdapterStub,
               adapter_options: [
                 search_queries: [
                   "Divinity II: The Dragon Knight Saga",
                   "Divinity II: The Dragon Knight Saga",
                   "Divinity II"
                 ]
               ]
             )

    assert recommended.status == "recommended"
    assert is_binary(recommended.selected_title)
    assert Repo.aggregate("ai_request_attempts", :count) == 4
  end

  test "stores provider diagnostics when model output is rejected" do
    {scope, _source} = unresolved_source("Invalid Output Fixture", 822)
    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(scope)

    config = Config.current()
    assert {:ok, review} = AI.claim_next(config)

    error = %Iri.AI.ProviderError{
      category: :invalid_response,
      message: "Model selected a candidate that was not supplied.",
      retryable: false,
      details: %{"model_output" => %{"action" => "match", "candidate_key" => "fake"}}
    }

    assert {:ok, failed} =
             AI.execute(review, config,
               adapter: AdapterStub,
               adapter_options: [error: error]
             )

    assert failed.status == "failed"
    assert failed.failure_details["model_output"]["candidate_key"] == "fake"
  end

  test "auto mode applies a clear AI rejection" do
    {scope, source} = unresolved_source("Reject Fixture", 820)
    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(scope)
    config = %{Config.current() | mode: :auto}
    assert {:ok, review} = AI.claim_next(config)

    assert {:ok, %MatchReview{status: "applied"}} =
             AI.execute(review, config,
               adapter: AdapterStub,
               adapter_options: [
                 action: "reject",
                 confidence: 0.99,
                 reason: "This is a dedicated server, not a playable game."
               ]
             )

    rejected = Repo.get!(GameSource, source.id)
    assert rejected.manual_lock
    assert rejected.catalog_kind == "rejected"
    assert rejected.match_method == "ai_rejected"
    assert rejected.game_id == nil

    audit = Repo.one!(AuditDecision)
    assert audit.actor_type == "ai"
    assert audit.action == "reject"
  end

  test "does not recommend store-only while an exact-title catalog candidate remains" do
    {scope, _source} = unresolved_source("Judgment", 823)
    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(scope)
    config = Config.current()
    assert {:ok, review} = AI.claim_next(config)

    assert {:ok, %MatchReview{status: "abstained", action: "abstain"} = abstained} =
             AI.execute(review, config,
               adapter: AdapterStub,
               adapter_options: [
                 action: "keep_store_only",
                 reason: "No supplied candidate is a defensible match."
               ]
             )

    assert abstained.reason =~ "Exact-title catalog candidates remain"
    assert abstained.selected_external_id == nil
  end

  test "a new prompt supersedes an active review made with an older prompt" do
    {scope, _source} = unresolved_source("Old Prompt Fixture", 821)
    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(scope)

    old_review = Repo.one!(MatchReview)
    old_review |> MatchReview.changeset(%{prompt_version: "1"}) |> Repo.update!()

    assert {:ok, %{queued: 1, existing: 0}} = AI.enqueue_unresolved(scope)
    assert Repo.get!(MatchReview, old_review.id).status == "superseded"
    assert Repo.aggregate(MatchReview, :count) == 2
  end

  test "transient errors retry, while authentication errors pause later claims" do
    {scope, _source} = unresolved_source("Retry Fixture", 801)
    {_scope, _source} = unresolved_source("Blocked Fixture", 802, scope.user)
    assert {:ok, %{queued: 2}} = AI.enqueue_unresolved(scope)

    config = Config.current()
    assert {:ok, review} = AI.claim_next(config)

    assert {:ok, retrying} =
             AI.execute(review, config,
               adapter: AdapterStub,
               adapter_options: [error: AdapterStub.rate_limited_error()]
             )

    assert retrying.status == "retry_wait"
    assert retrying.next_attempt_at

    retrying
    |> MatchReview.changeset(%{status: "queued", next_attempt_at: DateTime.utc_now(:second)})
    |> Repo.update!()

    assert {:ok, review} = AI.claim_next(config)

    assert {:ok, failed} =
             AI.execute(review, config,
               adapter: AdapterStub,
               adapter_options: [error: AdapterStub.authentication_error()]
             )

    assert failed.status == "failed"
    assert failed.last_error_category == "authentication"
    assert :none = AI.claim_next(config)
  end

  test "transient failures stop after the fixed fourth attempt" do
    {scope, _source} = unresolved_source("Exhausted Retry Fixture")
    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(scope)

    config = Config.current()
    assert {:ok, review} = AI.claim_next(config)

    review =
      review
      |> MatchReview.changeset(%{attempt_count: 4})
      |> Repo.update!()

    assert {:ok, failed} =
             AI.execute(review, config,
               adapter: AdapterStub,
               adapter_options: [error: AdapterStub.rate_limited_error()]
             )

    assert failed.status == "failed"
    assert failed.next_attempt_at == nil
  end

  test "an expired worker lease is reclaimed and counts as another durable attempt" do
    {scope, _source} = unresolved_source("Expired Lease Fixture")
    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(scope)

    config = Config.current()
    assert {:ok, claimed} = AI.claim_next(config)

    claimed
    |> MatchReview.changeset(%{lease_expires_at: DateTime.add(DateTime.utc_now(:second), -1)})
    |> Repo.update!()

    assert {:ok, reclaimed} = AI.claim_next(config)
    assert reclaimed.id == claimed.id
    assert reclaimed.lease_token != claimed.lease_token
    assert reclaimed.attempt_count == 2
    assert Repo.aggregate("ai_request_attempts", :count) == 2
  end

  test "the daily safety limit stops additional reviews" do
    {scope, _source} = unresolved_source("Budget Fixture One", 811)
    {_scope, _source} = unresolved_source("Budget Fixture Two", 812, scope.user)
    assert {:ok, %{queued: 2}} = AI.enqueue_unresolved(scope)

    config = Config.current()
    now = DateTime.utc_now(:second)

    review_id =
      Repo.one!(from review in MatchReview, order_by: review.id, limit: 1, select: review.id)

    Repo.insert_all(
      "ai_request_attempts",
      Enum.map(1..499, fn _ -> %{ai_match_review_id: review_id, attempted_at: now} end)
    )

    assert {:ok, review} = AI.claim_next(config, now)
    assert {:ok, _recommended} = AI.execute(review, config, adapter: AdapterStub)
    assert :none = AI.claim_next(config, now)
  end

  test "missing AI configuration leaves the deterministic flow available" do
    {scope, _source} = unresolved_source("No AI Fixture")
    Application.put_env(:iri, :ai_matching, %{provider: :disabled})

    assert {:error, {:ai_not_configured, :disabled}} = AI.enqueue_unresolved(scope)
    assert Repo.aggregate(MatchReview, :count) == 0
  end

  defp unresolved_source(title, app_id \\ 800, user \\ nil) do
    user = user || admin_user_fixture()
    scope = Scope.for_user(user)
    account = steam_account_fixture(user, app_id)

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => app_id, "name" => title}])

    {scope, Repo.get_by!(GameSource, provider: :steam, external_id: to_string(app_id))}
  end

  defp mark_deterministically_unresolved(source) do
    from(candidate in GameSource, where: candidate.id == ^source.id)
    |> Repo.update_all(set: [match_method: "ambiguous"])
  end

  defp steam_account_fixture(user, app_id) do
    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: :steam,
      external_user_id: Integer.to_string(76_561_198_000_000_000 + app_id),
      display_name: "AI fixture owner"
    })
    |> Ecto.Changeset.put_change(:owner_user_id, user.id)
    |> Repo.insert!()
  end
end
