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

defmodule Iri.Repo.Migrations.AddPlaytimeOffsetToUserGameStates do
  @moduledoc """
  Adds the per-user manual playtime offset and moves hours currently typed
  onto non-self-reporting items into it.

  The offset is personalization (like state/notes/rating): it is scoped by
  `(user_id, game_id)`, is never written by a provider sync, and is added on
  top of the store-reported hours. Store hours now sum across stores, so a
  value that used to be "the hours on this item" becomes "the user's extra
  hours for this game".
  """
  use Ecto.Migration

  def up do
    # The offset column. Storage is signed-wide (±6 000 000 minutes) so that
    # the open negative-offset decision is a pure app-layer change — the base
    # app-layer bound is 0…6 000 000 (0…100 000 hours).
    alter table(:user_game_states) do
      add :playtime_offset_minutes, :integer,
        null: false,
        default: 0,
        check: %{
          name: "user_game_states_playtime_offset_minutes_check",
          expr: "playtime_offset_minutes BETWEEN -6000000 AND 6000000"
        }
    end

    # The data steps are plain SQL statements (see data_migrations/0), so the
    # migration test can run the exact same statements it will run here.
    Enum.each(data_migrations(), &execute/1)
  end

  # Deliberately irreversible: the offset column has absorbed the hours of
  # the items zeroed below, so dropping the column would destroy the only
  # copy of those manual hours. It must raise rather than no-op: a
  # successful `down` would make Ecto delete the version row while the
  # column stays in the database, and the next `mix ecto.migrate` would then
  # fail with `duplicate column name: playtime_offset_minutes`. Reverting is
  # a manual data decision, not an automatic one.
  def down do
    raise Ecto.MigrationError,
      message:
        "irreversible: manual hours now live only in user_game_states.playtime_offset_minutes; restore from a backup"
  end

  @doc """
  The raw data-migration statements, in execution order.

  1. Move hours typed onto non-self-reporting items (custom/Epic/PSN) into
     the owning user's offset. Only hours the owner can still see count:
     hidden items, removed items, and items of disabled accounts are
     skipped, mirroring the visibility rules the rest of the app applies.
     Today the writer stamped the same value onto every editable item of a
     user's game, so per (account owner, game) the MAX of the item hours is
     the deduplicated typed value — SUM would triple-count it. The upsert
     ADDS to a pre-existing offset so already-personalized rows keep their
     value.
  2. Zero exactly the items whose hours were moved. The WHERE mirrors the
     upsert source set precisely (including owner_user_id IS NOT NULL), so
     hours sitting on owner-less shared accounts — personal to no one, hence
     with no offset target — are neither moved nor destroyed.
  """
  def data_migrations do
    [
      """
      INSERT INTO user_game_states (user_id, game_id, playtime_offset_minutes,
                                    inserted_at, updated_at)
      SELECT src.user_id, src.game_id, src.max_minutes,
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM (
        SELECT pa.owner_user_id AS user_id,
               gs.game_id AS game_id,
               MAX(li.playtime_minutes) AS max_minutes
        FROM library_items li
        JOIN game_sources gs ON gs.id = li.game_source_id
        JOIN provider_accounts pa ON pa.id = li.provider_account_id
        WHERE li.playtime_minutes > 0
          AND NOT li.hidden
          AND li.removed_at IS NULL
          AND pa.provider NOT IN ('steam', 'gog', 'xbox')
          AND pa.enabled
          AND gs.game_id IS NOT NULL
          AND pa.owner_user_id IS NOT NULL
        GROUP BY pa.owner_user_id, gs.game_id
      ) AS src
      -- SQLite grammar: in INSERT ... SELECT ... ON CONFLICT, a bare ON after
      -- the SELECT parses as a JOIN's ON clause (documented in parse.y). The
      -- documented fix is a dummy WHERE between the SELECT and the ON CONFLICT
      -- clause; without it the statement fails with `near "DO": syntax error`.
      WHERE true
      ON CONFLICT (user_id, game_id) DO UPDATE SET
        playtime_offset_minutes =
          user_game_states.playtime_offset_minutes + excluded.playtime_offset_minutes,
        updated_at = excluded.updated_at
      """,
      """
      UPDATE library_items
      SET playtime_minutes = 0,
          updated_at = CURRENT_TIMESTAMP
      WHERE id IN (
        SELECT li.id
        FROM library_items li
        JOIN game_sources gs ON gs.id = li.game_source_id
        JOIN provider_accounts pa ON pa.id = li.provider_account_id
        WHERE li.playtime_minutes > 0
          AND NOT li.hidden
          AND li.removed_at IS NULL
          AND pa.provider NOT IN ('steam', 'gog', 'xbox')
          AND pa.enabled
          AND gs.game_id IS NOT NULL
          AND pa.owner_user_id IS NOT NULL
      )
      """
    ]
  end
end
