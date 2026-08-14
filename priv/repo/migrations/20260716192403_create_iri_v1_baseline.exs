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

defmodule Iri.Repo.Migrations.CreateIriV1Baseline do
  use Ecto.Migration

  def change do
    create_accounts()
    create_library()
    create_ai_matching()
    create_sync_pipeline()
    create_collections()
    create_search_index()
  end

  defp create_accounts do
    create table(:users) do
      add :username, :string, null: false, collate: :nocase
      add :steam_id, :string
      add :hashed_password, :string
      add :sensitive_media_mode, :string, null: false, default: "inherit"

      add :role, :string,
        null: false,
        default: "viewer",
        check: %{name: "users_role_check", expr: "role IN ('admin', 'viewer')"}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:username])
    create unique_index(:users, [:steam_id], where: "steam_id IS NOT NULL")

    create table(:users_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false, size: 32
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:token])

    create table(:provider_accounts) do
      add :provider, :string,
        null: false,
        check: %{
          name: "provider_accounts_provider_check",
          expr: "provider IN ('steam', 'gog', 'custom', 'epic', 'psn', 'xbox')"
        }

      add :external_user_id, :string, null: false
      add :display_name, :string
      add :enabled, :boolean, null: false, default: true
      add :owner_user_id, references(:users, on_delete: :nilify_all)

      add :sharing_policy, :string,
        null: false,
        default: "inherit",
        check: %{
          name: "provider_accounts_sharing_policy_check",
          expr: "sharing_policy IN ('inherit', 'everyone', 'selected_users')"
        }

      add :sync_status, :string, null: false, default: "never_synced"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:provider_accounts, [:provider, :external_user_id])
    create index(:provider_accounts, [:provider, :enabled])
    create index(:provider_accounts, [:owner_user_id])
    create index(:provider_accounts, [:sharing_policy])

    create table(:provider_account_shares, primary_key: false) do
      add :provider_account_id,
          references(:provider_accounts, on_delete: :delete_all),
          primary_key: true

      add :user_id, references(:users, on_delete: :delete_all), primary_key: true
      timestamps(type: :utc_datetime, updated_at: false)
      add :linked, :boolean, null: false, default: true
    end

    create index(:provider_account_shares, [:user_id])

    alter table(:users) do
      add :main_steam_account_id, references(:provider_accounts, on_delete: :nilify_all)
    end

    create index(:users, [:main_steam_account_id])
  end

  defp create_library do
    create table(:games) do
      add :igdb_id, :integer
      add :vndb_id, :string
      add :nsfw, :boolean, null: false, default: false
      add :title, :string, null: false
      add :normalized_title, :string, null: false
      add :slug, :string, null: false
      add :summary, :text
      add :release_date, :date
      add :release_year, :integer
      add :rating, :float
      add :time_to_beat_main_seconds, :integer
      add :time_to_beat_extra_seconds, :integer
      add :nsfw_override, :boolean
      timestamps(type: :utc_datetime)
    end

    create unique_index(:games, [:igdb_id], where: "igdb_id IS NOT NULL")
    create unique_index(:games, [:vndb_id], where: "vndb_id IS NOT NULL")
    create unique_index(:games, [:slug])
    create index(:games, [:normalized_title])
    create index(:games, [:release_year])
    create index(:games, [:nsfw])

    create table(:game_sources) do
      add :provider, :string,
        null: false,
        check: %{
          name: "game_sources_provider_check",
          expr: "provider IN ('steam', 'gog', 'igdb', 'epic', 'psn', 'xbox')"
        }

      add :external_id, :string, null: false
      add :game_id, references(:games, on_delete: :nilify_all)
      add :source_title, :string, null: false
      add :normalized_source_title, :string
      add :source_url, :string
      add :metadata_snapshot, :map, null: false, default: %{}
      add :match_method, :string
      add :manual_lock, :boolean, null: false, default: false
      add :catalog_kind, :string
      add :controller_support, :string
      add :deck_compatibility, :string
      add :protondb_tier, :string
      add :protondb_etag, :string
      add :protondb_checked_at, :utc_datetime
      add :available_windows, :boolean
      add :available_mac, :boolean
      add :available_linux, :boolean
      add :vr_support, :string
      add :nsfw, :boolean, null: false, default: false
      add :compatibility_checked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:game_sources, [:provider, :external_id])
    create index(:game_sources, [:game_id])
    create index(:game_sources, [:match_method])
    create index(:game_sources, [:provider, :normalized_source_title, :id])
    create index(:game_sources, [:game_id, :manual_lock])
    create index(:game_sources, [:controller_support])
    create index(:game_sources, [:deck_compatibility])
    create index(:game_sources, [:protondb_tier])
    create index(:game_sources, [:vr_support])
    create index(:game_sources, [:catalog_kind])
    create index(:game_sources, [:nsfw])

    create table(:library_items) do
      add :provider_account_id,
          references(:provider_accounts, on_delete: :delete_all),
          null: false

      add :game_source_id, references(:game_sources, on_delete: :delete_all), null: false

      add :relationship, :string,
        null: false,
        default: "owned",
        check: %{
          name: "library_items_relationship_check",
          expr: "relationship IN ('owned', 'subscription', 'played', 'manual')"
        }

      add :hidden, :boolean, null: false, default: false
      add :playtime_minutes, :integer, null: false, default: 0
      add :manually_added, :boolean, null: false, default: false
      add :removed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:library_items, [:provider_account_id, :game_source_id])
    create index(:library_items, [:game_source_id])
    create index(:library_items, [:removed_at])
    create index(:library_items, [:relationship])

    create table(:taxonomy_terms) do
      add :source, :string, null: false
      add :external_id, :string, null: false
      add :kind, :string, null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:taxonomy_terms, [:source, :kind, :external_id])
    create index(:taxonomy_terms, [:kind, :name])

    create table(:game_terms, primary_key: false) do
      add :game_id, references(:games, on_delete: :delete_all), primary_key: true

      add :taxonomy_term_id,
          references(:taxonomy_terms, on_delete: :delete_all),
          primary_key: true
    end

    create index(:game_terms, [:taxonomy_term_id])

    create table(:companies) do
      add :source, :string, null: false
      add :external_id, :string, null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:companies, [:source, :external_id])
    create index(:companies, [:name])

    create table(:game_companies) do
      add :game_id, references(:games, on_delete: :delete_all), null: false
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :role, :string, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:game_companies, [:game_id, :company_id, :role])
    create index(:game_companies, [:company_id])

    create table(:media_assets) do
      add :game_id, references(:games, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :source, :string, null: false
      add :remote_id, :string
      add :remote_url, :string
      add :position, :integer, null: false, default: 0
      add :local_path, :string
      add :content_hash, :string
      add :cache_status, :string, null: false, default: "remote"
      timestamps(type: :utc_datetime)
    end

    create index(:media_assets, [:game_id, :kind, :position])

    create unique_index(:media_assets, [:game_id, :source, :kind, :remote_id],
             where: "remote_id IS NOT NULL"
           )

    create index(:media_assets, [:cache_status, :kind])

    create table(:user_game_states) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :game_id, references(:games, on_delete: :delete_all), null: false
      add :state, :string
      add :notes, :text

      add :rating, :float,
        check: %{
          name: "user_game_states_rating_check",
          expr: "rating BETWEEN 1 AND 5"
        }

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_game_states, [:user_id, :game_id])
    create index(:user_game_states, [:game_id])
    create index(:user_game_states, [:user_id, :rating])

    create table(:match_candidates) do
      add :game_source_id, references(:game_sources, on_delete: :delete_all), null: false
      add :igdb_id, :integer, null: false
      add :title, :string, null: false
      add :score, :float, null: false, default: 0.0
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:match_candidates, [:game_source_id, :igdb_id])
    create index(:match_candidates, [:game_source_id, :score])
  end

  defp create_ai_matching do
    create table(:ai_match_reviews) do
      add :game_source_id, references(:game_sources, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "queued"
      add :action, :string
      add :selected_catalog, :string
      add :selected_external_id, :string
      add :selected_title, :string
      add :confidence, :float
      add :reason, :text
      add :model, :string, null: false
      add :prompt_version, :string, null: false, default: "1"
      add :source_fingerprint, :string, null: false
      add :failure_details, :map, null: false, default: %{}
      add :attempt_count, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime
      add :lease_token, :string
      add :lease_expires_at, :utc_datetime
      add :last_error_category, :string
      add :last_error_message, :text
      timestamps(type: :utc_datetime)
    end

    create index(:ai_match_reviews, [:game_source_id, :inserted_at])
    create index(:ai_match_reviews, [:status, :next_attempt_at, :lease_expires_at])

    create unique_index(:ai_match_reviews, [:game_source_id],
             name: :ai_match_reviews_active_fingerprint_index,
             where:
               "status IN ('queued', 'running', 'retry_wait', 'recommended', 'abstained', 'failed')"
           )

    create table(:ai_request_attempts) do
      add :ai_match_review_id, references(:ai_match_reviews, on_delete: :delete_all), null: false
      add :attempted_at, :utc_datetime, null: false
    end

    create index(:ai_request_attempts, [:attempted_at])
    create index(:ai_request_attempts, [:ai_match_review_id])

    create table(:match_decisions) do
      add :game_source_id, references(:game_sources, on_delete: :delete_all), null: false
      add :ai_match_review_id, references(:ai_match_reviews, on_delete: :nilify_all)
      add :actor_type, :string, null: false
      add :admin_user_id, references(:users, on_delete: :nilify_all)
      add :action, :string, null: false
      add :selected_catalog, :string
      add :selected_external_id, :string
      add :reason, :text
      add :confidence, :float
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:match_decisions, [:game_source_id, :inserted_at])
    create index(:match_decisions, [:ai_match_review_id])
    create index(:match_decisions, [:admin_user_id])
    create index(:match_decisions, [:actor_type, :action])
  end

  defp create_sync_pipeline do
    create table(:sync_runs) do
      add :provider_account_id, references(:provider_accounts, on_delete: :nilify_all)
      add :provider, :string
      add :stage, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :checkpoint, :map, null: false, default: %{}
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :lease_expires_at, :utc_datetime
      add :discovered_count, :integer, null: false, default: 0
      add :inserted_count, :integer, null: false, default: 0
      add :updated_count, :integer, null: false, default: 0
      add :removed_count, :integer, null: false, default: 0
      add :matched_count, :integer, null: false, default: 0
      add :unmatched_count, :integer, null: false, default: 0
      add :failed_count, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create index(:sync_runs, [:status, :inserted_at])
    create index(:sync_runs, [:provider_account_id, :inserted_at])

    create unique_index(:sync_runs, [:provider_account_id],
             name: :sync_runs_one_active_per_account,
             where: "provider_account_id IS NOT NULL AND status IN ('queued', 'running')"
           )

    create index(:sync_runs, [:status, :lease_expires_at])

    create table(:sync_errors) do
      add :sync_run_id, references(:sync_runs, on_delete: :delete_all), null: false
      add :stage, :string, null: false
      add :kind, :string, null: false
      add :message, :string, null: false
      add :retryable, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create index(:sync_errors, [:sync_run_id])

    create table(:scheduled_tasks) do
      add :name, :string, null: false
      add :kind, :string, null: false
      add :status, :string, null: false, default: "idle"
      add :next_run_at, :utc_datetime, null: false
      add :lease_token, :string
      add :lease_expires_at, :utc_datetime
      add :consecutive_failures, :integer, null: false, default: 0
      add :last_finished_at, :utc_datetime
      add :last_error, :string
      add :rerun_requested, :boolean, null: false, default: false
      add :compatibility_requested, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:scheduled_tasks, [:name])
    create index(:scheduled_tasks, [:status, :next_run_at])
    create index(:scheduled_tasks, [:status, :lease_expires_at])

    create table(:provider_rate_limits) do
      add :provider, :string, null: false
      add :window_ends_at, :utc_datetime
      add :requests_observed, :integer, null: false, default: 0
      add :blocked_until, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:provider_rate_limits, [:provider])
    create index(:provider_rate_limits, [:blocked_until])
  end

  defp create_collections do
    create table(:collections) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false, collate: :nocase

      add :sharing_enabled, :boolean, null: false, default: false

      add :share_version, :integer,
        null: false,
        default: 1,
        check: %{name: "collections_share_version_check", expr: "share_version > 0"}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:collections, [:user_id, :name])
    create index(:collections, [:user_id, :updated_at])

    create table(:collection_games) do
      add :collection_id, references(:collections, on_delete: :delete_all), null: false
      add :game_id, references(:games, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :comment, :text
      timestamps(type: :utc_datetime)
    end

    create unique_index(:collection_games, [:collection_id, :game_id])
    create index(:collection_games, [:collection_id, :position])
    create index(:collection_games, [:game_id])
  end

  defp create_search_index do
    execute(
      """
      CREATE VIRTUAL TABLE library_search USING fts5(
        source_id UNINDEXED,
        title,
        source_title,
        summary,
        tokenize = 'unicode61 remove_diacritics 2'
      )
      """,
      "DROP TABLE IF EXISTS library_search"
    )

    execute(
      """
      CREATE TRIGGER library_search_source_insert
      AFTER INSERT ON game_sources
      BEGIN
        INSERT INTO library_search(source_id, title, source_title, summary)
        VALUES (
          new.id,
          COALESCE((SELECT title FROM games WHERE id = new.game_id), new.source_title),
          new.source_title,
          COALESCE((SELECT summary FROM games WHERE id = new.game_id), '')
        );
      END
      """,
      "DROP TRIGGER IF EXISTS library_search_source_insert"
    )

    execute(
      """
      CREATE TRIGGER library_search_source_update
      AFTER UPDATE OF source_title, game_id ON game_sources
      BEGIN
        DELETE FROM library_search WHERE source_id = old.id;
        INSERT INTO library_search(source_id, title, source_title, summary)
        VALUES (
          new.id,
          COALESCE((SELECT title FROM games WHERE id = new.game_id), new.source_title),
          new.source_title,
          COALESCE((SELECT summary FROM games WHERE id = new.game_id), '')
        );
      END
      """,
      "DROP TRIGGER IF EXISTS library_search_source_update"
    )

    execute(
      """
      CREATE TRIGGER library_search_source_delete
      AFTER DELETE ON game_sources
      BEGIN
        DELETE FROM library_search WHERE source_id = old.id;
      END
      """,
      "DROP TRIGGER IF EXISTS library_search_source_delete"
    )

    execute(
      """
      CREATE TRIGGER library_search_game_update
      AFTER UPDATE OF title, summary ON games
      BEGIN
        DELETE FROM library_search
        WHERE source_id IN (SELECT id FROM game_sources WHERE game_id = new.id);

        INSERT INTO library_search(source_id, title, source_title, summary)
        SELECT id, new.title, source_title, COALESCE(new.summary, '')
        FROM game_sources
        WHERE game_id = new.id;
      END
      """,
      "DROP TRIGGER IF EXISTS library_search_game_update"
    )
  end
end
