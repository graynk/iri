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

defmodule Mix.Tasks.Iri.PruneOrphans do
  @shortdoc "Deletes games and sources that no library item references"

  @moduledoc """
  Removes canonical games and provider sources that no library item references.

  Deleting a provider account used to leave its sources and games behind. IRI
  now prunes them as part of the deletion, so this task exists to clean up the
  residue left by earlier versions.

  The deletion cascades: cached media rows, personal completion state and
  ratings, collection entries, and matching history for those games all go with
  them. Take a backup first, and use `--dry-run` to see the counts.

      mix iri.prune_orphans --dry-run
      mix iri.prune_orphans

  Cached media files on disk are not touched; run the media maintenance
  schedule afterwards to reclaim them.
  """

  use Mix.Task

  alias Iri.Library
  alias Iri.Repo

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [dry_run: :boolean])

    if opts[:dry_run] do
      # Roll back rather than counting separately, so the preview and the real
      # run can never disagree about what qualifies as an orphan.
      {:error, counts} =
        Repo.transaction(fn ->
          {:ok, counts} = Library.prune_orphaned_games()
          Repo.rollback(counts)
        end)

      report("Would delete", counts)
    else
      {:ok, counts} = Library.prune_orphaned_games()
      report("Deleted", counts)
    end
  end

  defp report(verb, %{games: games, sources: sources}) do
    Mix.shell().info(
      "#{verb} #{games} canonical #{plural(games, "game")} and #{sources} provider #{plural(sources, "source")}."
    )
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
