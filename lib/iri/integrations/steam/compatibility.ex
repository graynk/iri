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

defmodule Iri.Integrations.Steam.Compatibility do
  @moduledoc "Refreshes cached compatibility metadata for locally owned Steam sources."

  import Ecto.Query, warn: false

  alias Iri.Integrations.{Error, ProtonDB}
  alias Iri.Integrations.Steam.StoreClient
  alias Iri.Library.GameSource
  alias Iri.Media.Classification
  alias Iri.Repo

  @refresh_after_days 7
  @store_rate_limit_resumes 3
  @store_rate_limit_fallback_ms 60_000
  @deck_batch_size 10
  @deck_batch_interval_ms 1_000
  @protondb_batch_size 10
  @protondb_batch_interval_ms 1_000

  def sync(options \\ []) do
    store_client = Keyword.get(options, :client, StoreClient)
    store_client_options = Keyword.get(options, :client_options, [])

    protondb_client =
      Keyword.get(
        options,
        :protondb_client,
        Application.get_env(:iri, :protondb_client, ProtonDB.Client)
      )

    protondb_client_options = Keyword.get(options, :protondb_client_options, [])
    protondb_gate = Keyword.get(options, :protondb_gate, fn -> :continue end)
    progress = Keyword.get(options, :progress, fn _details -> :ok end)
    throttle_ms = Keyword.get(options, :throttle_ms, 750)

    store_rate_limit_resumes =
      options
      |> Keyword.get(:store_rate_limit_resumes, @store_rate_limit_resumes)
      |> max(0)

    store_rate_limit_fallback_ms =
      options
      |> Keyword.get(:store_rate_limit_fallback_ms, @store_rate_limit_fallback_ms)
      |> max(0)

    sleep = Keyword.get(options, :sleep, &Process.sleep/1)

    deck_batch_size = options |> Keyword.get(:deck_batch_size, @deck_batch_size) |> max(1)

    deck_batch_interval_ms =
      Keyword.get(
        options,
        :deck_batch_interval_ms,
        if(throttle_ms == 0, do: 0, else: @deck_batch_interval_ms)
      )

    protondb_batch_size =
      options
      |> Keyword.get(:protondb_batch_size, @protondb_batch_size)
      |> max(1)

    protondb_batch_interval_ms =
      Keyword.get(
        options,
        :protondb_batch_interval_ms,
        if(throttle_ms == 0, do: 0, else: @protondb_batch_interval_ms)
      )

    force? = Keyword.get(options, :force, false)
    stale_before = DateTime.add(DateTime.utc_now(:second), -@refresh_after_days, :day)
    sources = active_sources()
    steam_sources = Enum.filter(sources, &steam_refresh_due?(&1, force?, stale_before))

    protondb_sources =
      Enum.filter(sources, &protondb_refresh_due?(&1, force?, stale_before))

    discovered_source_ids =
      (steam_sources ++ protondb_sources)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    state = %{
      step: "fetching_steam_details",
      processed_count: 0,
      total_count: length(steam_sources) * 2 + length(protondb_sources),
      discovered_count: MapSet.size(discovered_source_ids),
      updated_source_ids: MapSet.new(),
      steam_updated_count: 0,
      protondb_modified_count: 0,
      protondb_not_modified_count: 0,
      protondb_deferred_count: 0,
      failed_count: 0,
      failures: []
    }

    :ok = progress.(progress_details(state))

    state =
      run_store_phase(
        steam_sources,
        state,
        progress,
        store_client,
        store_client_options,
        store_rate_limit_resumes,
        store_rate_limit_fallback_ms,
        sleep
      )

    state = %{state | step: "fetching_deck_compatibility"}
    :ok = progress.(progress_details(state))

    state =
      run_deck_phase(
        steam_sources,
        state,
        deck_batch_size,
        deck_batch_interval_ms,
        progress,
        store_client,
        store_client_options
      )

    state =
      case protondb_gate.() do
        :continue ->
          state = %{state | step: "fetching_protondb"}
          :ok = progress.(progress_details(state))

          run_protondb_phase(
            protondb_sources,
            state,
            protondb_batch_size,
            protondb_batch_interval_ms,
            progress,
            protondb_client,
            protondb_client_options
          )

        :deferred ->
          %{
            state
            | total_count: state.processed_count,
              protondb_deferred_count: length(protondb_sources)
          }
      end

    {:ok, final_counts(state)}
  end

  defp active_sources do
    Repo.all(
      from source in GameSource,
        join: item in assoc(source, :library_items),
        join: account in assoc(item, :provider_account),
        where:
          source.provider == :steam and not item.hidden and
            is_nil(item.removed_at) and account.enabled,
        distinct: true,
        order_by: [asc: source.id]
    )
  end

  defp steam_refresh_due?(_source, true, _stale_before), do: true

  defp steam_refresh_due?(source, false, stale_before) do
    is_nil(source.catalog_kind) or stale?(source.compatibility_checked_at, stale_before)
  end

  defp protondb_refresh_due?(source, force?, stale_before) do
    source.catalog_kind in [nil, "game", "unknown"] and
      (force? or stale?(source.protondb_checked_at, stale_before))
  end

  defp stale?(nil, _stale_before), do: true

  defp stale?(%DateTime{} = checked_at, stale_before),
    do: DateTime.compare(checked_at, stale_before) == :lt

  defp run_store_phase(
         [],
         state,
         _progress,
         _client,
         _options,
         _resumes,
         _fallback_ms,
         _sleep
       ),
       do: state

  defp run_store_phase(
         sources,
         state,
         progress,
         client,
         client_options,
         resumes,
         fallback_ms,
         sleep
       ) do
    phase_count = length(sources)

    sources
    |> Enum.with_index(1)
    |> Enum.reduce_while(state, fn {source, phase_index}, state ->
      result =
        fetch_store_with_rate_limit_resume(
          source,
          client,
          client_options,
          resumes,
          fallback_ms,
          sleep
        )

      {control, state} = apply_store_result(source, result, state)
      state = Map.update!(state, :processed_count, &(&1 + 1))

      if phase_index == 1 or rem(phase_index, 10) == 0 or phase_index == phase_count do
        :ok = progress.(progress_details(state))
      end

      {control, state}
    end)
  end

  defp fetch_store_with_rate_limit_resume(
         source,
         client,
         client_options,
         resumes,
         fallback_ms,
         sleep
       ) do
    case client.fetch_store_metadata(source.external_id, client_options) do
      {:error, %Error{status: 429} = error} when resumes > 0 ->
        delay_ms = rate_limit_delay_ms(error, fallback_ms)
        sleep.(delay_ms)

        fetch_store_with_rate_limit_resume(
          source,
          client,
          client_options,
          resumes - 1,
          fallback_ms,
          sleep
        )

      result ->
        result
    end
  end

  defp rate_limit_delay_ms(%Error{retry_after_seconds: seconds}, _fallback_ms)
       when is_integer(seconds) and seconds >= 0,
       do: seconds * 1_000

  defp rate_limit_delay_ms(_error, fallback_ms), do: fallback_ms

  defp run_deck_phase([], state, _batch_size, _interval_ms, _progress, _client, _options),
    do: state

  defp run_deck_phase(
         sources,
         state,
         batch_size,
         interval_ms,
         progress,
         client,
         client_options
       ) do
    phase_count = length(sources)
    batches = sources |> Enum.with_index(1) |> Enum.chunk_every(batch_size)
    batch_count = length(batches)

    batches
    |> Enum.with_index(1)
    |> Enum.reduce_while(state, fn {batch, batch_index}, state ->
      started_at = System.monotonic_time(:millisecond)

      results =
        Task.async_stream(
          batch,
          fn {source, phase_index} ->
            {phase_index, source,
             client.fetch_deck_compatibility(source.external_id, client_options)}
          end,
          max_concurrency: batch_size,
          ordered: true,
          timeout: :infinity
        )

      {control, state} =
        Enum.reduce(results, {:cont, state}, fn
          {:ok, {phase_index, source, result}}, {batch_control, state} ->
            {result_control, state} = apply_deck_result(source, result, state)
            state = Map.update!(state, :processed_count, &(&1 + 1))

            if phase_index == 1 or rem(phase_index, 10) == 0 or phase_index == phase_count do
              :ok = progress.(progress_details(state))
            end

            control = if result_control == :halt, do: :halt, else: batch_control
            {control, state}

          {:exit, reason}, {_batch_control, _state} ->
            raise "Steam Deck request task exited: #{inspect(reason)}"
        end)

      if control == :cont and batch_index < batch_count do
        sleep_until_next_batch(started_at, interval_ms)
        {:cont, state}
      else
        {control, state}
      end
    end)
  end

  defp run_protondb_phase([], state, _batch_size, _interval_ms, _progress, _client, _options),
    do: state

  defp run_protondb_phase(
         sources,
         state,
         batch_size,
         interval_ms,
         progress,
         client,
         client_options
       ) do
    prepared_sources = Enum.map(sources, &prepare_protondb_source/1)
    phase_count = length(prepared_sources)
    batches = prepared_sources |> Enum.with_index(1) |> Enum.chunk_every(batch_size)
    batch_count = length(batches)

    batches
    |> Enum.with_index(1)
    |> Enum.reduce_while(state, fn {batch, batch_index}, state ->
      started_at = System.monotonic_time(:millisecond)

      results =
        Task.async_stream(
          batch,
          fn {prepared_source, phase_index} ->
            {phase_index, fetch_protondb_source(prepared_source, client, client_options)}
          end,
          max_concurrency: batch_size,
          ordered: true,
          timeout: :infinity
        )

      {control, state} =
        Enum.reduce(results, {:cont, state}, fn
          {:ok, {phase_index, result}}, {batch_control, state} ->
            {result_control, state} = apply_protondb_result(result, state)
            state = Map.update!(state, :processed_count, &(&1 + 1))

            if phase_index == 1 or rem(phase_index, 10) == 0 or phase_index == phase_count do
              :ok = progress.(progress_details(state))
            end

            control = if result_control == :halt, do: :halt, else: batch_control
            {control, state}

          {:exit, reason}, {_batch_control, _state} ->
            raise "ProtonDB request task exited: #{inspect(reason)}"
        end)

      if control == :cont and batch_index < batch_count do
        sleep_until_next_batch(started_at, interval_ms)
        {:cont, state}
      else
        {control, state}
      end
    end)
  end

  defp sleep_until_next_batch(_started_at, interval_ms) when interval_ms <= 0, do: :ok

  defp sleep_until_next_batch(started_at, interval_ms) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    remaining_ms = max(interval_ms - elapsed_ms, 0)
    if remaining_ms > 0, do: Process.sleep(remaining_ms)
  end

  defp apply_store_result(source, result, state) do
    case result do
      {:ok, attrs} ->
        attrs =
          attrs
          |> Map.put(:compatibility_checked_at, DateTime.utc_now(:second))
          |> ensure_catalog_kind(source)

        case update_source(source, attrs) do
          {:ok, updated_source} ->
            recompute_game_nsfw(updated_source)
            {:cont, mark_updated(state, source.id, :steam)}

          {:error, changeset} ->
            {:cont, record_failure(state, source, changeset, false, "Steam Store")}
        end

      {:error, :store_metadata_unavailable} ->
        persist_steam_source(source, %{}, state, "Steam Store")

      {:error, reason} ->
        state = record_failure(state, source, reason, retryable?(reason), "Steam Store")
        if rate_limited?(reason), do: {:halt, state}, else: {:cont, state}
    end
  end

  defp apply_deck_result(source, {:ok, compatibility}, state) do
    attrs = %{deck_compatibility: compatibility}

    case update_source(source, attrs) do
      {:ok, _updated_source} ->
        {:cont, mark_updated(state, source.id, :steam)}

      {:error, changeset} ->
        {:cont, record_failure(state, source, changeset, false, "Steam Deck")}
    end
  end

  defp apply_deck_result(source, {:error, reason}, state) do
    state = record_failure(state, source, reason, retryable?(reason), "Steam Deck")
    if rate_limited?(reason), do: {:halt, state}, else: {:cont, state}
  end

  defp persist_steam_source(source, attrs, state, service) do
    attrs =
      attrs
      |> Map.put(:compatibility_checked_at, DateTime.utc_now(:second))
      |> ensure_catalog_kind(source)

    case update_source(source, attrs) do
      {:ok, _updated_source} -> {:cont, mark_updated(state, source.id, :steam)}
      {:error, changeset} -> {:cont, record_failure(state, source, changeset, false, service)}
    end
  end

  defp prepare_protondb_source(source) do
    case Repo.get(GameSource, source.id) do
      %GameSource{catalog_kind: kind} when kind not in [nil, "game", "unknown"] ->
        :skip

      %GameSource{} = current_source ->
        {:fetch, current_source}

      nil ->
        :skip
    end
  end

  defp fetch_protondb_source(:skip, _client, _client_options), do: :skip

  defp fetch_protondb_source({:fetch, source}, client, client_options) do
    result = client.fetch_tier(source.external_id, source.protondb_etag, client_options)
    {:fetched, source, result}
  end

  defp apply_protondb_result(:skip, state), do: {:cont, state}

  defp apply_protondb_result({:fetched, source, result}, state) do
    case result do
      {:ok, :not_modified} ->
        persist_protondb(
          source,
          %{protondb_checked_at: DateTime.utc_now(:second)},
          state,
          :not_modified
        )

      {:ok, %{tier: tier, etag: etag}} ->
        persist_protondb(
          source,
          %{
            protondb_tier: tier,
            protondb_etag: etag,
            protondb_checked_at: DateTime.utc_now(:second)
          },
          state,
          :modified
        )

      {:error, reason} ->
        state = record_failure(state, source, reason, retryable?(reason), "ProtonDB")
        if rate_limited?(reason), do: {:halt, state}, else: {:cont, state}
    end
  end

  defp persist_protondb(source, attrs, state, result) do
    case update_source(source, attrs) do
      {:ok, _updated_source} ->
        {:cont, mark_updated(state, source.id, result)}

      {:error, changeset} ->
        {:cont, record_failure(state, source, changeset, false, "ProtonDB")}
    end
  end

  defp update_source(source, attrs) do
    Repo.transact_with_busy_retry(
      fn -> source |> GameSource.changeset(attrs) |> Repo.update() end,
      mode: :immediate
    )
  end

  # A source whose Steam store page is unavailable comes back without a
  # catalog_kind. Leaving it null keeps it perpetually eligible (the staleness
  # query treats null catalog_kind as "never classified"), so it would refetch
  # every run despite a fresh compatibility_checked_at. Mark it "unknown" once.
  defp ensure_catalog_kind(%{catalog_kind: kind} = attrs, _source) when is_binary(kind), do: attrs
  defp ensure_catalog_kind(attrs, %GameSource{catalog_kind: kind}) when is_binary(kind), do: attrs
  defp ensure_catalog_kind(attrs, _source), do: Map.put(attrs, :catalog_kind, "unknown")

  defp mark_updated(state, source_id, result) do
    already_updated? = MapSet.member?(state.updated_source_ids, source_id)
    state = Map.update!(state, :updated_source_ids, &MapSet.put(&1, source_id))

    case result do
      :steam when not already_updated? -> Map.update!(state, :steam_updated_count, &(&1 + 1))
      :steam -> state
      :modified -> Map.update!(state, :protondb_modified_count, &(&1 + 1))
      :not_modified -> Map.update!(state, :protondb_not_modified_count, &(&1 + 1))
    end
  end

  defp record_failure(state, source, reason, retryable?, service) do
    failure = %{
      kind: "item_failed",
      message:
        "#{source.source_title || "Steam app #{source.external_id}"} (#{service}, Steam #{source.external_id}): #{failure_message(reason)}",
      retryable: retryable?
    }

    state
    |> Map.update!(:failed_count, &(&1 + 1))
    |> Map.update!(:failures, fn failures -> Enum.take([failure | failures], 20) end)
  end

  defp progress_details(state) do
    %{
      step: state.step,
      processed_count: state.processed_count,
      total_count: state.total_count,
      discovered_count: state.discovered_count,
      updated_count: MapSet.size(state.updated_source_ids),
      failed_count: state.failed_count
    }
  end

  defp final_counts(state) do
    %{
      discovered_count: state.discovered_count,
      updated_count: MapSet.size(state.updated_source_ids),
      failed_count: state.failed_count,
      failures: state.failures,
      steam_updated_count: state.steam_updated_count,
      protondb_modified_count: state.protondb_modified_count,
      protondb_not_modified_count: state.protondb_not_modified_count,
      protondb_deferred_count: state.protondb_deferred_count
    }
  end

  defp failure_message(%Iri.Integrations.Error{message: message}), do: message

  defp failure_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _options} -> message end)
    |> Enum.map_join(", ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end

  defp failure_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_message(reason), do: inspect(reason, limit: 10, printable_limit: 300)

  defp retryable?(%Iri.Integrations.Error{retryable: retryable?}), do: retryable?
  defp retryable?(_reason), do: true

  defp rate_limited?(%Iri.Integrations.Error{status: 429}), do: true
  defp rate_limited?(_reason), do: false

  defp recompute_game_nsfw(%GameSource{game_id: game_id}) when is_integer(game_id) do
    _result = Classification.recompute_game(game_id)
    :ok
  end

  defp recompute_game_nsfw(_source), do: :ok
end
