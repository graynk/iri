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

defmodule Iri.Sync.SchedulerTest do
  use Iri.DataCase

  alias Iri.Repo
  alias Iri.Sync.{ScheduledTask, Scheduler}

  test "initializes recurring schedules in the configured local timezone" do
    original_time_zone = Application.get_env(:iri, :time_zone)
    Application.put_env(:iri, :time_zone, "Europe/Berlin")
    on_exit(fn -> Application.put_env(:iri, :time_zone, original_time_zone) end)

    assert :ok = Scheduler.ensure_tasks(~U[2026-07-15 00:30:00Z])

    assert Repo.get_by!(ScheduledTask, name: "nightly-library-maintenance").next_run_at ==
             ~U[2026-07-15 01:00:00Z]

    assert Repo.get_by!(ScheduledTask, name: "weekly-metadata-refresh").next_run_at ==
             ~U[2026-07-19 02:00:00Z]

    assert Repo.get_by!(ScheduledTask, name: "monthly-media-maintenance").next_run_at ==
             ~U[2026-08-01 03:00:00Z]
  end

  test "initializes scheduled work and persists exponential retry state" do
    now = DateTime.utc_now(:second)
    assert :ok = Scheduler.ensure_tasks(now)

    assert Repo.aggregate(ScheduledTask, :count) == 4
    assert length(Scheduler.list_tasks()) == 3

    task = Repo.get_by!(ScheduledTask, name: "nightly-library-maintenance")

    task =
      task
      |> Ecto.Changeset.change(next_run_at: DateTime.add(now, -1, :second))
      |> Repo.update!()

    assert [claimed] = Scheduler.claim_due_tasks(now)
    assert claimed.id == task.id
    assert claimed.status == :running
    assert is_binary(claimed.lease_token)
    assert :ok = Scheduler.heartbeat(claimed)

    assert :ok = Scheduler.complete(claimed, {:error, "temporary upstream failure", true})

    retried = Repo.get!(ScheduledTask, task.id)
    assert retried.status == :idle
    assert retried.consecutive_failures == 1
    assert retried.last_error == "temporary upstream failure"
    assert DateTime.diff(retried.next_run_at, now, :second) >= 300
  end

  test "takes over a scheduled task whose worker lease expired" do
    now = DateTime.utc_now(:second)
    assert :ok = Scheduler.ensure_tasks(now)

    task = Repo.get_by!(ScheduledTask, name: "weekly-metadata-refresh")

    task
    |> Ecto.Changeset.change(
      status: :running,
      lease_token: "abandoned-worker",
      lease_expires_at: DateTime.add(now, -1, :second)
    )
    |> Repo.update!()

    assert [claimed] = Scheduler.claim_due_tasks(now)
    assert claimed.id == task.id
    assert claimed.lease_token != "abandoned-worker"
  end

  test "refreshes a running task lease at most once per heartbeat interval" do
    now = DateTime.utc_now(:second)
    assert :ok = Scheduler.ensure_tasks(now)

    task = Repo.get_by!(ScheduledTask, name: "nightly-library-maintenance")

    task
    |> Ecto.Changeset.change(next_run_at: DateTime.add(now, -1, :second))
    |> Repo.update!()

    assert [claimed] = Scheduler.claim_due_tasks(now)
    original_expiry = claimed.lease_expires_at

    assert :ok =
             Scheduler.heartbeat(claimed.id, claimed.lease_token, DateTime.add(now, 1, :second))

    assert Repo.get!(ScheduledTask, claimed.id).lease_expires_at == original_expiry

    assert :ok =
             Scheduler.heartbeat(claimed.id, claimed.lease_token, DateTime.add(now, 60, :second))

    refreshed_expiry = Repo.get!(ScheduledTask, claimed.id).lease_expires_at
    assert DateTime.compare(refreshed_expiry, original_expiry) == :gt
  end

  test "coalesces imports into a durable on-demand enrichment task" do
    now = DateTime.utc_now(:second)
    assert :ok = Scheduler.enqueue_library_enrichment(now)

    assert [claimed] = Scheduler.claim_due_tasks(now)
    assert claimed.kind == "pending_library_enrichment"
    assert claimed.status == :running

    second_import_at = DateTime.add(now, 1, :second)
    assert :ok = Scheduler.enqueue_library_enrichment(second_import_at)
    assert :ok = Scheduler.complete(claimed, :ok)

    requeued = Repo.get!(ScheduledTask, claimed.id)
    assert requeued.status == :idle
    assert DateTime.compare(requeued.next_run_at, second_import_at) != :gt

    assert [second_claim] = Scheduler.claim_due_tasks(second_import_at)
    assert second_claim.id == claimed.id

    assert :ok = Scheduler.complete(second_claim, :ok)

    completed = Repo.get!(ScheduledTask, claimed.id)
    assert completed.status == :idle
    assert completed.next_run_at.year == 9999
  end

  test "hands compatibility requests to the runner and clears them for the next batch" do
    now = DateTime.utc_now(:second)
    assert :ok = Scheduler.enqueue_library_enrichment(now, compatibility: false)
    assert :ok = Scheduler.enqueue_library_enrichment(now, compatibility: true)
    assert :ok = Scheduler.enqueue_library_enrichment(now, compatibility: false)

    assert [claimed] = Scheduler.claim_due_tasks(now)
    assert claimed.compatibility_requested

    stored = Repo.get!(ScheduledTask, claimed.id)
    refute stored.compatibility_requested

    later = DateTime.add(now, 1, :second)
    assert :ok = Scheduler.enqueue_library_enrichment(later, compatibility: false)
    assert :ok = Scheduler.complete(claimed, :ok)

    assert [second_claim] = Scheduler.claim_due_tasks(later)
    refute second_claim.compatibility_requested
  end
end
