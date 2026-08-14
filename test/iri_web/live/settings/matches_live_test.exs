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

defmodule IriWeb.Settings.MatchesLiveTest do
  use IriWeb.ConnCase

  import Iri.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Iri.AI
  alias Iri.AI.{AdapterStub, Config, MatchReview}
  alias Iri.Integrations.ProviderAccount
  alias Iri.Integrations.Steam.Reconciler
  alias Iri.Library.GameSource
  alias Iri.Matches
  alias Iri.Repo

  test "admin searches and explicitly applies an unresolved match", %{conn: conn} do
    admin = admin_user_fixture()

    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 99, "name" => "Mystery Game"}])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "99")

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/matches")
    assert has_element?(view, "#ai-match-controls")
    assert has_element?(view, "#run-ai-matches.bg-teal-300[disabled]")
    assert has_element?(view, "#match-history-link")
    assert has_element?(view, "#candidate-search-form-#{source.id}")
    assert has_element?(view, "#vndb-search-form-#{source.id}")
    assert has_element?(view, "#vndb-search-query-#{source.id}")

    assert has_element?(
             view,
             "#candidate-search-query-#{source.id}-clearable[phx-hook='ClearableSearch']"
           )

    assert has_element?(
             view,
             "#vndb-search-query-#{source.id}-clearable[phx-hook='ClearableSearch']"
           )

    assert has_element?(view, "#reject-source-#{source.id}[data-confirm]")

    view
    |> form("#candidate-search-form-#{source.id}",
      candidate_search: %{source_id: source.id, query: "Alternate Mystery"}
    )
    |> render_submit()

    assert has_element?(view, "#apply-candidate-#{source.id}-90001")
    assert has_element?(view, "#apply-candidate-#{source.id}-90001", "Alternate Mystery")

    assert has_element?(
             view,
             "#apply-candidate-#{source.id}-90001 [data-role='developer']",
             "Fixture Studio"
           )

    assert has_element?(
             view,
             "#apply-candidate-#{source.id}-90001 [data-role='summary']",
             "searchable fixture game"
           )

    assert has_element?(view, "#apply-candidate-#{source.id}-90001", "2020")

    assert has_element?(
             view,
             "#apply-candidate-#{source.id}-90001 > [data-role='metadata']",
             "2020"
           )

    assert has_element?(
             view,
             "#candidate-search-query-#{source.id}[value='Alternate Mystery']"
           )

    refute has_element?(view, "#candidate-search-query-#{source.id}-clear[disabled]")

    view |> element("#apply-candidate-#{source.id}-90001") |> render_click()
    refute has_element?(view, "#sources-#{source.id}")
    assert Repo.get!(GameSource, source.id).manual_lock

    {:ok, history, _html} =
      conn |> recycle() |> log_in_user(admin) |> live(~p"/settings/matches/history")

    assert has_element?(history, "#decision-history-heading", "Decision history")
    assert has_element?(history, "#match-history", "Mystery Game")
    assert has_element?(history, "#reopen-source-#{source.id}", "Change match")
  end

  test "viewer cannot open match review", %{conn: conn} do
    viewer = viewer_user_fixture()

    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in_user(viewer) |> live(~p"/settings/matches")

    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in_user(viewer) |> live(~p"/settings/matches/history")
  end

  test "admin queues, reviews, approves, and reopens an AI recommendation", %{conn: conn} do
    previous = Application.get_env(:iri, :ai_matching)

    Application.put_env(:iri, :ai_matching, %{
      provider: :openai_compatible,
      model: "fixture-model",
      base_url: "http://localhost:11434/v1",
      mode: :review
    })

    on_exit(fn -> Application.put_env(:iri, :ai_matching, previous) end)

    admin = admin_user_fixture()
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 109, "name" => "AI Mystery"}])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "109")

    source
    |> Ecto.Changeset.change(match_method: "ambiguous")
    |> Repo.update!()

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/matches")
    assert has_element?(view, "#run-ai-matches[data-confirm]", "Run AI on unresolved")
    refute has_element?(view, "#run-ai-matches[disabled]")
    assert has_element?(view, "#ai-mode-description", "Review mode")

    view |> element("#run-ai-matches") |> render_click()
    review = Repo.one!(MatchReview)
    assert has_element?(view, "#ai-review-#{review.id}", "AI review queued")

    config = Config.current()
    assert {:ok, running} = AI.claim_next(config)
    assert {:ok, recommended} = AI.execute(running, config, adapter: AdapterStub)
    send(view.pid, :reviews_updated)
    assert has_element?(view, "#ai-review-#{recommended.id}", "Match AI Mystery")

    view |> element("#approve-ai-review-#{recommended.id}") |> render_click()
    refute has_element?(view, "#sources-#{source.id}")

    {:ok, history, _html} =
      conn |> recycle() |> log_in_user(admin) |> live(~p"/settings/matches/history")

    assert has_element?(history, "#match-history")
    assert has_element?(history, "#decision-history-heading", "Decision history")
    assert has_element?(history, "#match-history", "Fixture recommendation")
    assert has_element?(history, "#match-history", "Current")
    refute has_element?(history, "#resolved-match-sources")
    assert has_element?(history, "#reopen-source-#{source.id}")
    history |> element("#reopen-source-#{source.id}") |> render_click()
    assert_redirect(history, ~p"/settings/matches?source_id=#{source.id}")
    refute Repo.get!(GameSource, source.id).manual_lock
  end

  test "auto mode explains that matching runs after deterministic enrichment", %{conn: conn} do
    previous = Application.get_env(:iri, :ai_matching)

    Application.put_env(:iri, :ai_matching, %{
      provider: :openai_compatible,
      model: "fixture-model",
      base_url: "http://localhost:11434/v1",
      mode: :auto
    })

    on_exit(fn -> Application.put_env(:iri, :ai_matching, previous) end)

    admin = admin_user_fixture()
    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/matches")

    assert has_element?(view, "#ai-mode-description", "after deterministic metadata enrichment")
  end

  test "admin can clear pending AI reviews", %{conn: conn} do
    previous = Application.get_env(:iri, :ai_matching)

    Application.put_env(:iri, :ai_matching, %{
      provider: :openai_compatible,
      model: "fixture-model",
      base_url: "http://localhost:11434/v1",
      mode: :review
    })

    on_exit(fn -> Application.put_env(:iri, :ai_matching, previous) end)

    admin = admin_user_fixture()
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 112, "name" => "Queued AI Fixture"}])

    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(Iri.Accounts.Scope.for_user(admin))

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/matches")

    assert has_element?(
             view,
             "#ai-queue-summary > #clear-ai-queue[type=button][data-confirm]",
             "Clear pending"
           )

    view |> element("#clear-ai-queue") |> render_click()

    assert Repo.one!(MatchReview).status == "dismissed"
    refute has_element?(view, "#clear-ai-queue")
  end

  test "a failed AI review shows the rejected model output", %{conn: conn} do
    previous = Application.get_env(:iri, :ai_matching)

    Application.put_env(:iri, :ai_matching, %{
      provider: :openai_compatible,
      model: "fixture-model",
      base_url: "http://localhost:11434/v1",
      mode: :review
    })

    on_exit(fn -> Application.put_env(:iri, :ai_matching, previous) end)

    admin = admin_user_fixture()
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 111, "name" => "Broken AI Output"}])

    assert {:ok, %{queued: 1}} = AI.enqueue_unresolved(Iri.Accounts.Scope.for_user(admin))
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

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/matches")

    assert has_element?(
             view,
             "#ai-review-model-output-#{failed.id}",
             "\"candidate_key\": \"fake\""
           )

    refute has_element?(view, "#retry-ai-matches")
  end

  test "an already reopened decision can be continued or rejected as a non-game", %{conn: conn} do
    admin = admin_user_fixture()
    scope = Iri.Accounts.Scope.for_user(admin)
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 110, "name" => "LIV Software"}])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "110")
    assert {:ok, _ignored} = Matches.ignore_source(scope, source.id)
    assert {:ok, _reopened} = Matches.reopen_source(scope, source.id)

    logged_in_conn = log_in_user(conn, admin)

    {:ok, queue, _html} =
      live(logged_in_conn, ~p"/settings/matches?source_id=#{source.id}")

    assert has_element?(
             queue,
             "#reject-source-#{source.id}[data-confirm]",
             "Reject as non-game"
           )

    assert has_element?(queue, "#focused-source-help-#{source.id}", "software")

    {:ok, history, _html} =
      conn
      |> recycle()
      |> log_in_user(admin)
      |> live(~p"/settings/matches/history")

    assert has_element?(
             history,
             "#continue-review-#{source.id}[href='/settings/matches?source_id=#{source.id}']"
           )

    assert has_element?(
             history,
             "#reject-reopened-source-#{source.id}[data-confirm]",
             "Reject as non-game"
           )

    history |> element("#reject-reopened-source-#{source.id}") |> render_click()

    rejected = Repo.get!(GameSource, source.id)
    assert rejected.manual_lock
    assert rejected.match_method == "rejected"
    assert rejected.catalog_kind == "rejected"
    refute has_element?(history, "#reopened-actions-#{source.id}")
    assert has_element?(history, "#match-history", "Rejected as a non-game")
  end

  test "admin applies an exact IGDB ID without searching", %{conn: conn} do
    admin = admin_user_fixture()
    account = steam_account_fixture()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [%{"appid" => 101, "name" => "Call of Duty®"}])

    source = Repo.get_by!(GameSource, provider: :steam, external_id: "101")
    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/matches")

    view
    |> form("#direct-igdb-form-#{source.id}", direct_match: %{igdb_id: "90001"})
    |> render_submit()

    refute has_element?(view, "#sources-#{source.id}")
    assert Repo.get!(GameSource, source.id).match_method == "manual_id"
  end

  defp steam_account_fixture do
    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: :steam,
      external_user_id: "76561198000000001",
      display_name: "Owner"
    })
    |> Repo.insert!()
  end
end
