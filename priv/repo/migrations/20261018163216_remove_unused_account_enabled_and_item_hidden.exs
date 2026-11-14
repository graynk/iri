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

defmodule Iri.Repo.Migrations.RemoveUnusedAccountEnabledAndItemHidden do
  use Ecto.Migration

  def up do
    %{rows: [[disabled_accounts]]} =
      repo().query!("SELECT count(*) FROM provider_accounts WHERE enabled = 0")

    if disabled_accounts > 0 do
      raise "Cannot remove enabled: #{disabled_accounts} disabled accounts require an explicit disposition"
    end

    # Source-level decisions are authoritative, including sources already reopened
    # while their legacy hidden flag remained set. Do not rewrite those decisions
    # or infer the reason for an ownership removal from the obsolete hidden flag.

    drop index(:provider_accounts, [:provider, :enabled])

    alter table(:provider_accounts) do
      remove :enabled
    end

    alter table(:library_items) do
      remove :hidden
    end
  end

  def down do
    raise Ecto.MigrationError,
          "Cannot restore discarded visibility flags; restore a pre-migration database backup instead"
  end
end
