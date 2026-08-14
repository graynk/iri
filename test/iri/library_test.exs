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

defmodule Iri.LibraryTest do
  use Iri.DataCase

  import Iri.AccountsFixtures

  alias Iri.Accounts.Scope
  alias Iri.Integrations.ProviderAccount
  alias Iri.Integrations
  alias Iri.Integrations.GOG.ClientStub, as: GOGClientStub
  alias Iri.Integrations.GOG.Reconciler, as: GOGReconciler
  alias Iri.Integrations.IGDB.{ClientStub, Enricher}
  alias Iri.Integrations.Steam.Reconciler
  alias Iri.Library
  alias Iri.Library.{Game, GameSource, Personalization, TaxonomyTerm}

  test "lists locally owned source games once across multiple Steam owners" do
    first = steam_account_fixture("76561198000000001", "First owner")
    second = steam_account_fixture("76561198000000002", "Second owner")
    games = games_fixture()

    assert {:ok, _counts} = Reconciler.reconcile(first, games)
    assert {:ok, _counts} = Reconciler.reconcile(second, games)

    scope = viewer_user_fixture() |> Scope.for_user()

    assert {:ok, page} = Library.list_source_games(scope)

    assert page.total_count == 2
    assert Enum.map(page.entries, & &1.source_title) == ["Counter-Strike", "Portal 2"]
    assert Enum.all?(page.entries, &(length(&1.library_items) == 2))
  end

  test "counts the viewer's completion states across the effective library" do
    account = steam_account_fixture("76561198000000001", "Owner")

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [
               %{"appid" => 10, "name" => "Completed fixture"},
               %{"appid" => 20, "name" => "Dropped fixture"},
               %{"appid" => 30, "name" => "Playing fixture"},
               %{"appid" => 40, "name" => "Backlog fixture"}
             ])

    assert {:ok, _counts} =
             Enricher.enrich(
               %{"steam_source_id" => 1},
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    scope = viewer_user_fixture() |> Scope.for_user()

    games =
      Repo.all(
        from game in Game,
          order_by: game.igdb_id
      )

    for {game, state} <-
          Enum.zip(games, ["completed", "dropped", "playing", "backlog"]) do
      assert {:ok, _state} = Library.set_game_state(scope, game.id, state)
    end

    assert {:ok,
            %{
              "completed" => 1,
              "dropped" => 1,
              "playing" => 1,
              "backlog" => 1
            }} = Library.completion_state_counts(scope)

    assert {:error, :unauthorized} = Library.completion_state_counts(nil)
  end

  test "searches normalized source titles locally" do
    account = steam_account_fixture("76561198000000001", "Owner")
    assert {:ok, _counts} = Reconciler.reconcile(account, games_fixture())

    scope = viewer_user_fixture() |> Scope.for_user()
    assert {:ok, page} = Library.list_source_games(scope, %{"q" => "portal"})

    assert page.total_count == 1
    assert [%{source_title: "Portal 2"}] = page.entries
  end

  test "searches canonical descriptions and keeps the local index current" do
    account = steam_account_fixture("76561198000000001", "Owner")
    assert {:ok, _counts} = Reconciler.reconcile(account, [List.first(games_fixture())])

    assert {:ok, _counts} =
             Enricher.enrich(
               %{"steam_source_id" => 1},
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    scope = viewer_user_fixture() |> Scope.for_user()

    assert {:ok, %{total_count: 1}} =
             Library.list_source_games(scope, %{"q" => "fixture description"})

    game = Repo.one!(Game)
    game |> Game.changeset(%{summary: "A nebula orchard adventure."}) |> Repo.update!()

    assert {:ok, %{total_count: 1}} = Library.list_source_games(scope, %{"q" => "nebula orch"})

    assert {:ok, %{total_count: 0}} =
             Library.list_source_games(scope, %{"q" => "fixture description"})
  end

  test "only admins can override and restore sensitive-media classification" do
    account = steam_account_fixture("76561198000000001", "Owner")
    assert {:ok, _counts} = Reconciler.reconcile(account, [List.first(games_fixture())])

    assert {:ok, _counts} =
             Enricher.enrich(
               %{"steam_source_id" => 1},
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    source = Repo.one!(GameSource)
    source |> Ecto.Changeset.change(nsfw: true) |> Repo.update!()
    game = Repo.get!(Game, source.game_id)
    game |> Ecto.Changeset.change(nsfw: true) |> Repo.update!()

    viewer_scope = viewer_user_fixture() |> Scope.for_user()
    assert {:error, :unauthorized} = Library.mark_game_not_sensitive(viewer_scope, game.id)

    admin_scope = admin_user_fixture() |> Scope.for_user()
    assert {:ok, overridden} = Library.mark_game_not_sensitive(admin_scope, game.id)
    refute overridden.nsfw
    assert overridden.nsfw_override == false

    source |> Ecto.Changeset.change(nsfw: false) |> Repo.update!()

    assert {:ok, overridden} = Library.mark_game_sensitive(admin_scope, game.id)
    assert overridden.nsfw
    assert overridden.nsfw_override
  end

  test "filters ownership by provider and connected library" do
    steam = steam_account_fixture("76561198000000001", "Steam owner")
    gog = gog_account_fixture()
    assert {:ok, _counts} = Reconciler.reconcile(steam, games_fixture())
    assert {:ok, gog_games} = GOGClientStub.fetch_library(gog, %{}, [])
    assert {:ok, _counts} = GOGReconciler.reconcile(gog, Enum.take(gog_games, 1))

    scope = viewer_user_fixture() |> Scope.for_user()

    assert {:ok, %{total_count: 1}} =
             Library.list_source_games(scope, %{"provider" => "gog"})

    assert {:ok, %{total_count: 2}} =
             Library.list_source_games(scope, %{"account_id" => Integer.to_string(steam.id)})

    assert {:ok, %{total_count: 3}} =
             Library.list_source_games(scope, %{
               "providers" => ["steam", "gog"],
               "account_ids" => [Integer.to_string(steam.id), Integer.to_string(gog.id)]
             })

    assert {:ok, options} = Library.list_filter_options(scope)
    assert Enum.map(options.accounts, & &1.id) |> Enum.sort() == Enum.sort([steam.id, gog.id])
  end

  test "restricts selected libraries to the owner and explicit shares" do
    admin = admin_user_fixture()
    owner = viewer_user_fixture()
    shared = viewer_user_fixture()
    excluded = viewer_user_fixture()
    account = steam_account_fixture("76561198000000001", "Private owner")

    account
    |> Ecto.Changeset.change(owner_user_id: owner.id)
    |> Repo.update!()

    assert {:ok, _counts} = Reconciler.reconcile(account, games_fixture())

    assert {:ok, _account} =
             Integrations.update_provider_account_access(Scope.for_user(owner), account.id, %{
               "sharing_policy" => "selected_users",
               "shared_user_ids" => [Integer.to_string(shared.id)]
             })

    assert {:ok, %{total_count: 0}} = Library.list_source_games(Scope.for_user(admin))
    assert {:ok, %{total_count: 2}} = Library.list_source_games(Scope.for_user(owner))
    assert {:ok, %{total_count: 2}} = Library.list_source_games(Scope.for_user(shared))
    assert {:ok, %{total_count: 0}} = Library.list_source_games(Scope.for_user(excluded))
  end

  test "presents Open world and 4X as genres without rewriting IGDB taxonomy" do
    account = steam_account_fixture("76561198000000001", "Owner")
    assert {:ok, _counts} = Reconciler.reconcile(account, [List.first(games_fixture())])

    assert {:ok, _counts} =
             Enricher.enrich(
               %{"steam_source_id" => 1},
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    game = Repo.one!(Game)

    for {external_id, name} <- [{"38", "Open world"}, {"41", "4X"}] do
      term =
        %TaxonomyTerm{}
        |> TaxonomyTerm.changeset(%{
          source: "igdb",
          external_id: external_id,
          kind: "theme",
          name: name,
          slug: Iri.Library.Title.slug(name)
        })
        |> Repo.insert!()

      Repo.insert_all("game_terms", [%{game_id: game.id, taxonomy_term_id: term.id}])
      assert term.kind == "theme"
      assert TaxonomyTerm.presentation_kind(term) == "genre"
    end

    scope = viewer_user_fixture() |> Scope.for_user()
    assert {:ok, options} = Library.list_filter_options(scope)

    genre_names = Enum.map(options.genres, & &1.name)
    theme_names = Enum.map(options.themes, & &1.name)
    assert "Open world" in genre_names
    assert "4X" in genre_names
    refute "Open world" in theme_names
    refute "4X" in theme_names
  end

  test "deduplicates equivalent tag casing and filters across provider terms" do
    account = steam_account_fixture("76561198000000001", "Owner")
    assert {:ok, _counts} = Reconciler.reconcile(account, games_fixture())

    assert {:ok, _counts} =
             Enricher.enrich(
               %{"steam_source_id" => 1},
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    [first_game_id, second_game_id] =
      Repo.all(from game in Game, order_by: game.id, select: game.id)

    lower =
      %TaxonomyTerm{}
      |> TaxonomyTerm.changeset(%{
        source: "igdb",
        external_id: "case-lower",
        kind: "keyword",
        name: "sexual content",
        slug: "sexual-content"
      })
      |> Repo.insert!()

    title_case =
      %TaxonomyTerm{}
      |> TaxonomyTerm.changeset(%{
        source: "vndb",
        external_id: "case-title",
        kind: "keyword",
        name: "Sexual Content",
        slug: "sexual-content"
      })
      |> Repo.insert!()

    Repo.insert_all("game_terms", [
      %{game_id: first_game_id, taxonomy_term_id: lower.id},
      %{game_id: second_game_id, taxonomy_term_id: title_case.id}
    ])

    scope = viewer_user_fixture() |> Scope.for_user()
    assert {:ok, [suggestion]} = Library.list_tag_suggestions(scope, "sexual content")
    assert suggestion.name == "Sexual content"

    assert {:ok, page} =
             Library.list_source_games(scope, %{"tag_ids" => [Integer.to_string(suggestion.id)]})

    assert page.total_count == 2

    assert {:ok, []} =
             Library.list_tag_suggestions(scope, "sexual content", [
               Integer.to_string(suggestion.id)
             ])

    perspective =
      taxonomy_term_fixture(
        [first_game_id],
        "player_perspective",
        "First person",
        "perspective-1"
      )

    assert {:ok, [perspective_suggestion]} =
             Library.list_tag_suggestions(scope, "first person")

    assert perspective_suggestion.id == perspective.id
    assert perspective_suggestion.name == "First person"

    assert {:ok, intersection} =
             Library.list_source_games(scope, %{
               "tag_ids" => [
                 Integer.to_string(suggestion.id),
                 Integer.to_string(perspective.id)
               ]
             })

    assert intersection.total_count == 1
    assert hd(intersection.entries).game_id == first_game_id
  end

  test "requires every selected genre, theme, game mode, and tag" do
    account = steam_account_fixture("76561198000000001", "Owner")
    assert {:ok, _counts} = Reconciler.reconcile(account, games_fixture())

    assert {:ok, _counts} =
             Enricher.enrich(
               %{"steam_source_id" => 1},
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    first = Repo.get_by!(GameSource, provider: :steam, external_id: "10")
    second = Repo.get_by!(GameSource, provider: :steam, external_id: "620")

    common_genre = Repo.get_by!(TaxonomyTerm, kind: "genre", name: "Role-playing (RPG)")
    common_theme = Repo.get_by!(TaxonomyTerm, kind: "theme", name: "Science fiction")
    common_mode = Repo.get_by!(TaxonomyTerm, kind: "game_mode", name: "Single player")

    extra_genre = taxonomy_term_fixture([first.game_id], "genre", "Tactical", "and-genre")
    extra_theme = taxonomy_term_fixture([first.game_id], "theme", "Mystery", "and-theme")
    extra_mode = taxonomy_term_fixture([first.game_id], "game_mode", "Co-operative", "and-mode")

    common_tag =
      taxonomy_term_fixture(
        [first.game_id, second.game_id],
        "keyword",
        "Combat",
        "and-tag-common"
      )

    extra_tag = taxonomy_term_fixture([first.game_id], "keyword", "Stealth", "and-tag-extra")

    scope = viewer_user_fixture() |> Scope.for_user()

    for {key, ids} <- [
          {"genre_ids", [common_genre.id, extra_genre.id]},
          {"theme_ids", [common_theme.id, extra_theme.id]},
          {"game_modes", [common_mode.id, extra_mode.id]},
          {"tag_ids", [common_tag.id, extra_tag.id]}
        ] do
      assert {:ok, %{entries: [entry], total_count: 1}} =
               Library.list_source_games(scope, %{key => Enum.map(ids, &Integer.to_string/1)})

      assert entry.game_id == first.game_id
    end
  end

  test "sorts by IGDB rating and filters store compatibility metadata" do
    account = steam_account_fixture("76561198000000001", "Owner")
    assert {:ok, _counts} = Reconciler.reconcile(account, games_fixture())

    assert {:ok, _counts} =
             Enricher.enrich(
               %{"steam_source_id" => 1},
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    counter_strike = Repo.get_by!(Iri.Library.GameSource, provider: :steam, external_id: "10")
    portal = Repo.get_by!(Iri.Library.GameSource, provider: :steam, external_id: "620")

    counter_strike.game_id
    |> then(&Repo.get!(Game, &1))
    |> Game.changeset(%{rating: 42.0})
    |> Repo.update!()

    portal.game_id
    |> then(&Repo.get!(Game, &1))
    |> Game.changeset(%{rating: 96.0})
    |> Repo.update!()

    counter_strike
    |> Iri.Library.GameSource.changeset(%{
      controller_support: "full",
      deck_compatibility: "verified",
      protondb_tier: "gold",
      available_windows: true,
      available_linux: true,
      vr_support: "supported"
    })
    |> Repo.update!()

    portal
    |> Iri.Library.GameSource.changeset(%{
      deck_compatibility: "unknown",
      protondb_tier: "silver"
    })
    |> Repo.update!()

    keyword =
      %TaxonomyTerm{}
      |> TaxonomyTerm.changeset(%{
        source: "igdb",
        external_id: "70002",
        kind: "keyword",
        name: "Female protagonist",
        slug: "female-protagonist"
      })
      |> Repo.insert!()

    Repo.insert_all("game_terms", [
      %{game_id: counter_strike.game_id, taxonomy_term_id: keyword.id}
    ])

    user = viewer_user_fixture()

    account
    |> Ecto.Changeset.change(owner_user_id: user.id)
    |> Repo.update!()

    user =
      user
      |> Ecto.Changeset.change(steam_id: account.external_user_id)
      |> Repo.update!()

    scope = Scope.for_user(user)

    family_account =
      steam_account_fixture("76561198000000002", "Family member")
      |> Ecto.Changeset.change(owner_user_id: user.id)
      |> Repo.update!()

    assert {:ok, _counts} =
             Reconciler.reconcile(family_account, [
               %{"appid" => 10, "name" => "Counter-Strike", "playtime_forever" => 1_000},
               %{"appid" => 620, "name" => "Portal 2", "playtime_forever" => 5}
             ])

    assert {:ok, rating_page} = Library.list_source_games(scope, %{"sort" => "rating_desc"})
    assert Enum.map(rating_page.entries, & &1.external_id) == ["620", "10"]

    assert {:ok, _preferences} = Personalization.set_rating(scope, counter_strike.game_id, 1)

    assert {:ok, personal_page} =
             Library.list_source_games(scope, %{"sort" => "my_rating_desc"})

    assert Enum.map(personal_page.entries, & &1.external_id) == ["10", "620"]

    assert {:ok, _preferences} = Personalization.set_rating(scope, portal.game_id, 5)

    assert {:ok, personal_page} =
             Library.list_source_games(scope, %{"sort" => "my_rating_desc"})

    assert Enum.map(personal_page.entries, & &1.external_id) == ["620", "10"]

    # Playtime is the viewer's own only: it comes from the linked personal
    # account (10 => 60, 620 => 120), not the family account's separate hours.
    assert {:ok, playtime_desc} =
             Library.list_source_games(scope, %{"sort" => "playtime", "direction" => "desc"})

    assert Enum.map(playtime_desc.entries, & &1.external_id) == ["620", "10"]

    assert {:ok, playtime_asc} =
             Library.list_source_games(scope, %{"sort" => "playtime", "direction" => "asc"})

    assert Enum.map(playtime_asc.entries, & &1.external_id) == ["10", "620"]

    other_scope = viewer_user_fixture() |> Scope.for_user()

    assert {:ok, other_page} =
             Library.list_source_games(other_scope, %{"sort" => "my_rating_desc"})

    assert Enum.map(other_page.entries, & &1.external_id) == ["10", "620"]

    for params <- [
          %{"controllers" => ["full"]},
          %{"deck" => ["ideal"]},
          %{"platforms" => ["linux"]},
          %{"game_modes" => ["vr"]},
          %{"tag_ids" => [Integer.to_string(keyword.id)]}
        ] do
      assert {:ok, %{total_count: 1, entries: [entry]}} =
               Library.list_source_games(scope, params)

      assert entry.external_id == "10"
    end

    assert {:ok, %{total_count: 1, entries: [playable]}} =
             Library.list_source_games(scope, %{"deck" => ["playable"]})

    assert playable.external_id == "620"

    assert {:ok, _state} = Library.set_game_state(scope, counter_strike.game_id, "playing")
    assert {:ok, _state} = Library.set_game_state(scope, portal.game_id, "completed")

    assert {:ok, %{total_count: 1, entries: [playing]}} =
             Library.list_source_games(scope, %{"states" => ["playing"]})

    assert playing.external_id == "10"

    assert {:ok, %{total_count: 0}} =
             Library.list_source_games(scope, %{"states" => ["not_played"]})

    assert {:ok, %{total_count: 2}} =
             Library.list_source_games(scope, %{
               "states" => ["playing", "completed"]
             })

    assert {:ok, _state} = Library.clear_game_state(scope, counter_strike.game_id)

    assert {:ok, %{total_count: 1, entries: [not_played]}} =
             Library.list_source_games(scope, %{"states" => ["not_played"]})

    assert not_played.external_id == "10"

    assert {:ok, %{total_count: 2}} =
             Library.list_source_games(scope, %{
               "states" => ["not_played", "completed"]
             })

    assert {:ok, _state} = Library.set_game_state(scope, counter_strike.game_id, "backlog")

    assert {:ok, %{total_count: 1, entries: [wanted]}} =
             Library.list_source_games(scope, %{"states" => ["backlog"]})

    assert wanted.external_id == "10"

    assert {:ok, %{total_count: 0}} =
             Library.list_source_games(scope, %{"states" => ["not_played"]})
  end

  test "sorts matched games by release year and always leaves unknown games last" do
    account = steam_account_fixture("76561198000000001", "Owner")
    assert {:ok, _counts} = Reconciler.reconcile(account, games_fixture())

    assert {:ok, _counts} =
             Enricher.enrich(
               %{"steam_source_id" => 1},
               client: ClientStub,
               cache_cover: fn _game_id, _options -> {:ok, :no_cover} end
             )

    counter_strike = Repo.get_by!(GameSource, provider: :steam, external_id: "10")
    portal = Repo.get_by!(GameSource, provider: :steam, external_id: "620")

    counter_strike.game_id
    |> then(&Repo.get!(Game, &1))
    |> Game.changeset(%{release_year: 2010})
    |> Repo.update!()

    portal.game_id
    |> then(&Repo.get!(Game, &1))
    |> Game.changeset(%{release_year: 2020})
    |> Repo.update!()

    assert {:ok, _counts} =
             Reconciler.reconcile(account, [
               %{"appid" => 10, "name" => "Counter-Strike"},
               %{"appid" => 620, "name" => "Portal 2"},
               %{"appid" => 999, "name" => "Unmatched fixture"}
             ])

    scope = viewer_user_fixture() |> Scope.for_user()

    assert {:ok, descending} =
             Library.list_source_games(scope, %{
               "sort" => "release_year",
               "direction" => "desc"
             })

    assert descending.filters["sort"] == "release_year"
    assert Enum.map(descending.entries, & &1.external_id) == ["620", "10", "999"]

    assert {:ok, ascending} =
             Library.list_source_games(scope, %{
               "sort" => "release_year",
               "direction" => "asc"
             })

    assert Enum.map(ascending.entries, & &1.external_id) == ["10", "620", "999"]
  end

  test "paginates deterministically across equal personal ratings" do
    account = steam_account_fixture("76561198000000001", "Owner")

    games =
      Enum.map(1..55, fn appid ->
        %{
          "appid" => appid,
          "name" => "Rated Game #{String.pad_leading(Integer.to_string(appid), 3, "0")}",
          "playtime_forever" => 0
        }
      end)

    assert {:ok, _counts} = Reconciler.reconcile(account, games)
    scope = viewer_user_fixture() |> Scope.for_user()

    Iri.Library.GameSource
    |> order_by(asc: :id)
    |> Repo.all()
    |> Enum.each(fn source ->
      game =
        %Game{}
        |> Game.changeset(%{
          title: source.source_title,
          normalized_title: source.normalized_source_title,
          slug: "rated-game-#{source.external_id}"
        })
        |> Repo.insert!()

      source
      |> Iri.Library.GameSource.changeset(%{game_id: game.id})
      |> Repo.update!()

      assert {:ok, _preferences} = Personalization.set_rating(scope, game.id, 3)
    end)

    assert {:ok, first_page} =
             Library.list_source_games(scope, %{"sort" => "my_rating_desc"})

    assert length(first_page.entries) == 48
    assert first_page.page == 1
    assert first_page.page_count == 2

    assert {:ok, second_page} =
             Library.list_source_games(scope, %{
               "sort" => "my_rating_desc",
               "page" => "2"
             })

    assert length(second_page.entries) == 7
    assert second_page.page == 2

    assert MapSet.disjoint?(
             MapSet.new(first_page.entries, & &1.id),
             MapSet.new(second_page.entries, & &1.id)
           )
  end

  @tag timeout: 120_000
  test "paginates deterministically across 5,000 generated games without loading them all" do
    account = steam_account_fixture("76561198000000001", "Owner")

    games =
      Enum.map(1..5_000, fn appid ->
        %{
          "appid" => appid,
          "name" => "Fixture Game #{String.pad_leading(Integer.to_string(appid), 4, "0")}",
          "playtime_forever" => 0
        }
      end)

    assert {:ok, _counts} = Reconciler.reconcile(account, games)
    scope = viewer_user_fixture() |> Scope.for_user()

    assert {:ok, first_page} = Library.list_source_games(scope)
    assert length(first_page.entries) == 48
    assert first_page.total_count == 5_000
    assert first_page.page == 1
    assert first_page.page_count == 105

    assert {:ok, second_page} =
             Library.list_source_games(scope, %{"page" => "2"})

    assert length(second_page.entries) == 48
    assert second_page.page == 2

    assert MapSet.disjoint?(
             MapSet.new(first_page.entries, & &1.id),
             MapSet.new(second_page.entries, & &1.id)
           )

    assert {:ok, last_page} = Library.list_source_games(scope, %{"page" => "999"})
    assert last_page.page == 105
    assert length(last_page.entries) == 8
  end

  defp steam_account_fixture(steamid, name) do
    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: :steam,
      external_user_id: steamid,
      display_name: name
    })
    |> Repo.insert!()
  end

  defp gog_account_fixture do
    %ProviderAccount{}
    |> ProviderAccount.changeset(%{
      provider: :gog,
      external_user_id: "48628349971017",
      display_name: "GOG owner"
    })
    |> Repo.insert!()
  end

  defp games_fixture do
    [
      %{"appid" => 10, "name" => "Counter-Strike", "playtime_forever" => 60},
      %{"appid" => 620, "name" => "Portal 2", "playtime_forever" => 120}
    ]
  end

  defp taxonomy_term_fixture(game_ids, kind, name, external_id) do
    term =
      %TaxonomyTerm{}
      |> TaxonomyTerm.changeset(%{
        source: "igdb",
        external_id: external_id,
        kind: kind,
        name: name,
        slug: Iri.Library.Title.slug(name)
      })
      |> Repo.insert!()

    Repo.insert_all(
      "game_terms",
      Enum.map(game_ids, &%{game_id: &1, taxonomy_term_id: term.id})
    )

    term
  end
end
