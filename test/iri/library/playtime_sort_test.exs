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

defmodule Iri.Library.PlaytimeSortTest do
  @moduledoc """
  Sort/display parity for the playtime ordering: the SQL sort key must equal
  the clamped total the read paths show — store hours summed across stores,
  plus the per-user manual offset, floored at zero.
  """

  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Accounts.Scope
  alias Iri.Integrations.ProviderAccount
  alias Iri.Library
  alias Iri.Library.{Game, GameSource, LibraryItem, Personalization, StatusManager, UserGameState}
  alias Iri.Repo

  test "store hours sum across stores in the playtime sort" do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)

    game_a = game_fixture("alpha sum")
    item_fixture(user, game_a, :gog, "sum-gog-a", 2400)
    item_fixture(user, game_a, :steam, "sum-steam-a", 1500)

    game_b = game_fixture("beta sum")
    item_fixture(user, game_b, :psn, "sum-psn-b", 3000)

    # 2400 + 1500 = 3900 beats 3000; the old max() key (2400) would not.
    assert {:ok, %{entries: [a, b]}} =
             Library.list_source_games(scope, %{"sort" => "playtime", "direction" => "desc"})

    assert [a.game_id, b.game_id] == [game_a.id, game_b.id]

    assert {:ok, %{entries: [b2, a2]}} =
             Library.list_source_games(scope, %{"sort" => "playtime", "direction" => "asc"})

    assert [b2.game_id, a2.game_id] == [game_b.id, game_a.id]
  end

  test "a game the viewer sees but owns no items in ranks by its offset" do
    user = viewer_user_fixture()
    owner = viewer_user_fixture()
    scope = Scope.for_user(user)

    # The viewer reaches the game through the owner's shared item; they have
    # no personal items of their own.
    shared_game = game_fixture("alpha offset only")
    shared_account = account_fixture(owner, :custom, "offset-shared", :inherit)
    shared_source = source_fixture(shared_game, :custom, "offset-shared-igdb")
    make_item(shared_account, shared_source, 240)

    assert {:ok, _} = Personalization.set_playtime_offset(scope, shared_game.id, 300)

    game_b = game_fixture("beta items only")
    item_fixture(user, game_b, :psn, "offset-psn-b", 240)

    # The item-driven subquery produces no row for the shared game, so only
    # the outer fragment's offset keeps it ranked by its displayed total.
    assert {:ok, %{entries: [a, b]}} =
             Library.list_source_games(scope, %{"sort" => "playtime", "direction" => "desc"})

    assert [a.game_id, b.game_id] == [shared_game.id, game_b.id]

    assert {:ok, %{entries: [b2, a2]}} =
             Library.list_source_games(scope, %{"sort" => "playtime", "direction" => "asc"})

    assert [b2.game_id, a2.game_id] == [game_b.id, shared_game.id]
  end

  test "a corrupted negative offset clamps the sort key at zero" do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)

    game_a = game_fixture("alpha clamp")
    item_fixture(user, game_a, :steam, "clamp-steam-a", 120)

    # Bypass the write guards: a negative offset can only exist via the open
    # negative decision, a future write bug, or a corrupted row.
    Repo.insert!(%UserGameState{
      user_id: user.id,
      game_id: game_a.id,
      playtime_offset_minutes: -600
    })

    game_b = game_fixture("beta clamp")
    item_fixture(user, game_b, :psn, "clamp-psn-b", 240)

    game_c = game_fixture("zeta clamp")

    # The hourless game is reachable only through a shared item of its own.
    owner = viewer_user_fixture()
    owner_account = account_fixture(owner, :custom, "clamp-shared-c", :inherit)
    owner_source = source_fixture(game_c, :custom, "clamp-shared-c-igdb")
    make_item(owner_account, owner_source, 0)

    # 120 - 600 clamps to 0 and ties with the hourless game; the normalized
    # title breaks the tie.
    assert {:ok, %{entries: [b, a, c]}} =
             Library.list_source_games(scope, %{"sort" => "playtime", "direction" => "desc"})

    assert [b.game_id, a.game_id, c.game_id] == [game_b.id, game_a.id, game_c.id]

    assert {:ok, %{entries: [a2, c2, b2]}} =
             Library.list_source_games(scope, %{"sort" => "playtime", "direction" => "asc"})

    assert [a2.game_id, c2.game_id, b2.game_id] == [game_a.id, game_c.id, game_b.id]
  end

  test "each viewer ranks by their own hours and offset only" do
    user = viewer_user_fixture()
    stranger = viewer_user_fixture()
    scope = Scope.for_user(user)
    stranger_scope = Scope.for_user(stranger)

    shared_game = game_fixture("alpha shared")

    # The viewer's shared custom item (2h) plus their 999-minute offset.
    account = account_fixture(user, :custom, "shared-custom", :inherit)
    source = source_fixture(shared_game, :custom, "shared-igdb")
    make_item(account, source, 600)
    assert {:ok, _} = Personalization.set_playtime_offset(scope, shared_game.id, 999)

    # The viewer's private 1580-minute game.
    private_game = game_fixture("beta private")
    item_fixture(user, private_game, :psn, "private-psn", 1580)

    # The stranger's own 200-minute game.
    stranger_game = game_fixture("gamma stranger")
    item_fixture(stranger, stranger_game, :psn, "stranger-psn", 200)

    # Viewer: shared 600 + offset 999 = 1599 beats the private 1580.
    assert {:ok, %{entries: [shared, private]}} =
             Library.list_source_games(scope, %{"sort" => "playtime", "direction" => "desc"})

    assert [shared.game_id, private.game_id] == [shared_game.id, private_game.id]

    # Stranger: their own 200 minutes beat the shared game's key of 0 — the
    # viewer's 600 minutes and 999-minute offset never leak across.
    assert {:ok, %{entries: [stranger_entry, shared_entry]}} =
             Library.list_source_games(stranger_scope, %{
               "sort" => "playtime",
               "direction" => "desc"
             })

    assert [stranger_entry.game_id, shared_entry.game_id] == [stranger_game.id, shared_game.id]
  end

  test "a bare unmatched source ranks by its own item sum, with no offset" do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)

    account = account_fixture(user, :custom, "bare-custom", :selected_users)

    bare_source = source_fixture(nil, :custom, "bare-source-1")
    make_item(account, bare_source, 900)

    game_a = game_fixture("alpha bare")
    item_fixture(user, game_a, :psn, "bare-psn-a", 1200)

    assert {:ok, %{entries: [a, bare]}} =
             Library.list_source_games(scope, %{"sort" => "playtime", "direction" => "desc"})

    assert a.game_id == game_a.id
    assert bare.id == bare_source.id
    assert is_nil(bare.game_id)
  end

  test "the status manager playtime sort matches the library sort" do
    user = viewer_user_fixture()
    scope = Scope.for_user(user)

    game_a = game_fixture("alpha parity")
    item_fixture(user, game_a, :gog, "parity-gog-a", 2400)
    item_fixture(user, game_a, :steam, "parity-steam-a", 1500)

    game_b = game_fixture("beta parity")
    item_fixture(user, game_b, :psn, "parity-psn-b", 3000)

    assert {:ok, %{entries: library_entries}} =
             Library.list_source_games(scope, %{"sort" => "playtime", "direction" => "desc"})

    assert {:ok, %{entries: status_entries}} =
             StatusManager.list_games(scope, %{"sort" => "playtime", "direction" => "desc"})

    library_ids = Enum.map(library_entries, & &1.game_id)
    assert library_ids == [game_a.id, game_b.id]
    assert Enum.map(status_entries, & &1.id) == library_ids

    assert {:ok, %{entries: library_asc}} =
             Library.list_source_games(scope, %{"sort" => "playtime", "direction" => "asc"})

    assert {:ok, %{entries: status_asc}} =
             StatusManager.list_games(scope, %{"sort" => "playtime", "direction" => "asc"})

    library_asc_ids = Enum.map(library_asc, & &1.game_id)
    assert library_asc_ids == [game_b.id, game_a.id]
    assert Enum.map(status_asc, & &1.id) == library_asc_ids
  end

  defp game_fixture(title) do
    %Game{}
    |> Game.changeset(%{
      title: title,
      normalized_title: String.downcase(title),
      slug:
        "#{String.downcase(String.replace(title, " ", "-"))}-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp account_fixture(owner, provider, external_id, sharing_policy) do
    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: provider,
      external_user_id: external_id,
      display_name: "#{provider} account",
      sharing_policy: sharing_policy
    })
    |> Ecto.Changeset.put_change(:owner_user_id, owner.id)
    |> Repo.insert!()
  end

  defp source_fixture(game, provider, external_id) do
    %GameSource{}
    |> GameSource.changeset(%{
      provider: if(provider == :custom, do: :igdb, else: provider),
      external_id: external_id,
      source_title: (game && game.title) || "Bare Source Game",
      normalized_source_title: (game && game.normalized_title) || "bare source game",
      game_id: game && game.id,
      catalog_kind: "game"
    })
    |> Repo.insert!()
  end

  defp item_fixture(user, game, provider, external_id, playtime_minutes) do
    account = account_fixture(user, provider, external_id, :selected_users)
    source = source_fixture(game, provider, external_id)
    make_item(account, source, playtime_minutes)
  end

  defp make_item(account, source, playtime_minutes) do
    %LibraryItem{}
    |> LibraryItem.changeset(%{
      provider_account_id: account.id,
      game_source_id: source.id,
      playtime_minutes: playtime_minutes
    })
    |> Repo.insert!()
  end
end
