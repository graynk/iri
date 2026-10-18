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

defmodule Iri.RemoveLegacyVisibilityMigrationTest do
  use ExUnit.Case, async: false

  alias Iri.MigrationRepo, as: Repo

  @moduletag :tmp_dir
  @moduletag capture_log: true
  @baseline 20_260_716_192_403
  @migration 20_261_018_163_216
  @migrations [
    {@baseline, Iri.Repo.Migrations.CreateIriV1Baseline},
    {@migration, Iri.Repo.Migrations.RemoveUnusedAccountEnabledAndItemHidden}
  ]

  setup_all do
    for {version, module} <- @migrations do
      unless Code.ensure_loaded?(module) do
        [path] =
          Path.wildcard(Path.expand("../../priv/repo/migrations/#{version}_*.exs", __DIR__))

        Code.require_file(path)
      end
    end

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    start_supervised!({Repo, database: Path.join(tmp_dir, "migration.db"), pool_size: 2})
    Ecto.Migrator.run(Repo, @migrations, :up, to: @baseline, log: false)

    Repo.query!("""
    INSERT INTO provider_accounts (id, provider, external_user_id, inserted_at, updated_at)
    VALUES (1, 'steam', 'migration-fixture', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
    """)

    for {id, method, hidden, removed, relationship} <- [
          {1, nil, 0, nil, "owned"},
          {2, "rejected", 1, nil, "played"},
          {3, "rejected", 1, "2026-02-01 00:00:00", "manual"},
          {4, nil, 0, "2026-02-01 00:00:00", "owned"},
          {5, "ai_rejected", 1, nil, "owned"},
          {6, nil, 1, nil, "owned"}
        ] do
      Repo.query!(
        """
        INSERT INTO game_sources
          (id, provider, external_id, source_title, match_method, catalog_kind, inserted_at, updated_at)
        VALUES (?, 'steam', ?, 'Migration fixture', ?, 'game', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
        """,
        [id, to_string(id), method]
      )

      Repo.query!(
        """
        INSERT INTO library_items
          (id, provider_account_id, game_source_id, hidden, removed_at, relationship, inserted_at, updated_at)
        VALUES (?, 1, ?, ?, ?, ?, '2026-01-01 00:00:00', '2026-01-01 00:00:00')
        """,
        [id, id, hidden, removed, relationship]
      )
    end

    Repo.query!(
      "UPDATE game_sources SET catalog_kind = 'rejected', manual_lock = 1 WHERE id IN (2, 3, 5)"
    )

    Repo.query!("UPDATE game_sources SET catalog_kind = 'unknown' WHERE id = 6")

    :ok
  end

  test "drops obsolete flags while preserving ownership, relationships and real removals" do
    before_items =
      Repo.query!(
        "SELECT id, relationship, removed_at, inserted_at, updated_at FROM library_items ORDER BY id"
      ).rows

    before_sources = Repo.query!("SELECT * FROM game_sources ORDER BY id").rows

    assert [@migration] = Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)
    refute "enabled" in columns("provider_accounts")
    refute "hidden" in columns("library_items")

    assert Repo.query!(
             "SELECT id, relationship, removed_at, inserted_at, updated_at FROM library_items ORDER BY id"
           ).rows == before_items

    assert Repo.query!("SELECT id, removed_at FROM library_items ORDER BY id").rows == [
             [1, nil],
             [2, nil],
             [3, "2026-02-01 00:00:00"],
             [4, "2026-02-01 00:00:00"],
             [5, nil],
             [6, nil]
           ]

    assert Repo.query!("SELECT * FROM game_sources ORDER BY id").rows == before_sources

    assert Repo.query!("PRAGMA foreign_key_check").rows == []
    assert Repo.query!("PRAGMA integrity_check").rows == [["ok"]]

    assert_raise Ecto.MigrationError, ~r/restore a pre-migration database backup/, fn ->
      Ecto.Migrator.run(Repo, @migrations, :down, step: 1, log: false)
    end

    refute "enabled" in columns("provider_accounts")
    refute "hidden" in columns("library_items")
    assert Repo.query!("SELECT * FROM game_sources ORDER BY id").rows == before_sources
  end

  test "refuses to silently activate disabled accounts without changing data" do
    Repo.query!("UPDATE provider_accounts SET enabled = 0 WHERE id = 1")
    before_items = Repo.query!("SELECT * FROM library_items ORDER BY id").rows
    before_sources = Repo.query!("SELECT * FROM game_sources ORDER BY id").rows

    assert_raise RuntimeError, ~r/1 disabled accounts require an explicit disposition/, fn ->
      Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)
    end

    assert "hidden" in columns("library_items")
    assert "enabled" in columns("provider_accounts")
    assert Repo.query!("SELECT enabled FROM provider_accounts").rows == [[0]]
    assert Repo.query!("SELECT * FROM library_items ORDER BY id").rows == before_items
    assert Repo.query!("SELECT * FROM game_sources ORDER BY id").rows == before_sources

    assert Repo.query!("SELECT removed_at FROM library_items WHERE id = 3").rows == [
             ["2026-02-01 00:00:00"]
           ]
  end

  defp columns(table) do
    Repo.query!("SELECT name FROM pragma_table_info(?)", [table]).rows |> List.flatten()
  end
end
