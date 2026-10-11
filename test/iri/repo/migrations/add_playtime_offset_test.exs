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

defmodule Iri.Repo.Migrations.AddPlaytimeOffsetToUserGameStatesTest do
  @moduledoc """
  Runs the exact data statements the migration executes (see
  `data_migrations/0`) against seeded fixtures and asserts the move, the
  zeroing, and idempotency. The column DDL itself is covered by the fact that
  the whole suite runs on the migrated test database.
  """

  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Integrations.ProviderAccount
  alias Iri.Library.{Game, GameSource, LibraryItem, UserGameState}
  alias Iri.Repo.Migrations.AddPlaytimeOffsetToUserGameStates

  # Migration modules are not compiled into the app; the migrator loads them
  # from disk on demand. Load this one so the test can run the exact
  # statements it will execute.
  @migration_path Path.wildcard(
                    Path.expand(
                      "../../../../priv/repo/migrations/*_add_playtime_offset_to_user_game_states.exs",
                      __DIR__
                    )
                  )

  @compile {:no_warn_undefined, Iri.Repo.Migrations.AddPlaytimeOffsetToUserGameStates}

  setup_all do
    Code.eval_file(Enum.at(@migration_path, 0))
    :ok
  end

  test "moves typed hours into per-user offsets, dedupes with MAX, and adds to pre-existing" do
    user = viewer_user_fixture()
    stranger = viewer_user_fixture()
    game = game_fixture()

    psn_item = item_fixture(user, game, :psn, "migrate-psn", 750)
    epic_item = item_fixture(user, game, :epic, "migrate-epic", 750)
    custom_item = item_fixture(user, game, :custom, "migrate-custom", 400)
    gog_item = item_fixture(user, game, :gog, "migrate-gog", 300)
    stranger_psn_item = item_fixture(stranger, game, :psn, "migrate-psn-2", 300)
    unmatched_item = item_fixture(user, nil, :custom, "migrate-unmatched", 400)
    ownerless_item = item_fixture(nil, game, :custom, "migrate-ownerless", 500)

    %UserGameState{user_id: user.id, game_id: game.id}
    |> Ecto.Changeset.change(
      playtime_offset_minutes: 120,
      rating: 4.0,
      state: "playing"
    )
    |> Repo.insert!()

    run_migration_data()

    # 750/750/400 all describe the same typed value -> MAX (750), added to the
    # pre-existing 120. The personal state fields survive the upsert.
    assert %UserGameState{playtime_offset_minutes: 870, rating: 4.0, state: "playing"} =
             Repo.get_by!(UserGameState, user_id: user.id, game_id: game.id)

    # The stranger's hours land in the stranger's offset, untouched by the
    # user's migration.
    assert Repo.get_by!(UserGameState, user_id: stranger.id, game_id: game.id).playtime_offset_minutes ==
             300

    # Exactly the moved items are zeroed ...
    assert Repo.get!(LibraryItem, psn_item.id).playtime_minutes == 0
    assert Repo.get!(LibraryItem, epic_item.id).playtime_minutes == 0
    assert Repo.get!(LibraryItem, custom_item.id).playtime_minutes == 0
    assert Repo.get!(LibraryItem, stranger_psn_item.id).playtime_minutes == 0

    # ... while self-reporting, unmatched, and owner-less hours stay put.
    assert Repo.get!(LibraryItem, gog_item.id).playtime_minutes == 300
    assert Repo.get!(LibraryItem, unmatched_item.id).playtime_minutes == 400
    assert Repo.get!(LibraryItem, ownerless_item.id).playtime_minutes == 500

    # Re-running the statements is a no-op: the items are already zero, so
    # nothing is moved or added again.
    run_migration_data()

    assert Repo.get_by!(UserGameState, user_id: user.id, game_id: game.id).playtime_offset_minutes ==
             870

    assert Repo.get_by!(UserGameState, user_id: stranger.id, game_id: game.id).playtime_offset_minutes ==
             300

    assert Enum.all?(Repo.all(LibraryItem), &(&1.playtime_minutes in [0, 300, 400, 500]))
  end

  test "the offset column rejects values outside the signed-wide bound" do
    user = viewer_user_fixture()
    game = game_fixture()

    # Raw insert bypasses the app-layer validators: the DB check constraint
    # itself must reject the value.
    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%UserGameState{
        user_id: user.id,
        game_id: game.id,
        playtime_offset_minutes: 6_000_001
      })
    end

    # The base app-layer bound is 0...6 000 000; the storage bound is signed
    # for the open negative-offset decision.
    assert %UserGameState{} =
             Repo.insert!(%UserGameState{
               user_id: user.id,
               game_id: game.id,
               playtime_offset_minutes: -600
             })
  end

  test "down fails loudly, because the migration is irreversible" do
    # A no-op down would make Ecto mark the rollback as successful while the
    # column stays in the database; the next forward migration would then fail
    # on the duplicate column. The rollback must fail loudly instead.
    assert_raise Ecto.MigrationError, fn ->
      AddPlaytimeOffsetToUserGameStates.down()
    end
  end

  defp run_migration_data do
    for sql <- AddPlaytimeOffsetToUserGameStates.data_migrations() do
      Repo.query!(sql)
    end
  end

  defp game_fixture do
    %Game{}
    |> Game.changeset(%{
      title: "Migrate Game",
      normalized_title: "migrate game",
      slug: "migrate-game-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp item_fixture(owner, game, provider, external_id, playtime_minutes) do
    changeset =
      %ProviderAccount{}
      |> ProviderAccount.changeset(%{
        provider: provider,
        external_user_id: external_id,
        display_name: "#{provider} account",
        sharing_policy: :inherit
      })

    changeset =
      if owner do
        Ecto.Changeset.put_change(changeset, :owner_user_id, owner.id)
      else
        changeset
      end

    account = Repo.insert!(changeset)

    source =
      %GameSource{}
      |> GameSource.changeset(%{
        provider: if(provider == :custom, do: :igdb, else: provider),
        external_id: external_id,
        source_title: "Migrate Game",
        normalized_source_title: "migrate game",
        game_id: game && game.id,
        catalog_kind: "game"
      })
      |> Repo.insert!()

    %LibraryItem{}
    |> LibraryItem.changeset(%{
      provider_account_id: account.id,
      game_source_id: source.id,
      playtime_minutes: playtime_minutes
    })
    |> Repo.insert!()
  end
end
