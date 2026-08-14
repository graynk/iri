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

defmodule Iri.Library.Companies do
  @moduledoc "Scoped browsing of companies represented in a viewer's effective library."

  import Ecto.Query, warn: false

  alias Iri.Accounts.Scope

  alias Iri.Library.{
    Access,
    Company,
    Game,
    GameCompany,
    GameSource,
    LibraryItem,
    MediaAsset,
    UserGameState
  }

  alias Iri.Params
  alias Iri.Repo

  @doc "Loads a company and its canonical games limited to the viewer's accessible library."
  def get_in_library(%Scope{user: user} = scope, company_id) when not is_nil(user) do
    with company_id when not is_nil(company_id) <- Params.positive_integer(company_id),
         %Company{} = company <- accessible_company(scope, company_id) do
      games =
        company_id
        |> company_games(scope)
        |> preload_cards(scope, company_id)

      {:ok, %{company: company, games: games, total_count: length(games)}}
    else
      _missing -> {:error, :not_found}
    end
  end

  def get_in_library(_scope, _company_id), do: {:error, :unauthorized}

  defp accessible_company(scope, company_id) do
    Repo.one(
      from company in Company,
        join: relation in GameCompany,
        on: relation.company_id == company.id,
        where:
          company.id == ^company_id and
            relation.game_id in subquery(Access.game_ids(scope)),
        distinct: true
    )
  end

  defp company_games(company_id, scope) do
    Repo.all(
      from game in Game,
        join: relation in GameCompany,
        on: relation.game_id == game.id,
        where:
          relation.company_id == ^company_id and
            game.id in subquery(Access.game_ids(scope)),
        distinct: true,
        order_by: [asc: game.normalized_title, asc: game.id]
    )
  end

  defp preload_cards(games, %Scope{user: user} = scope, company_id) do
    accessible_account_ids = Access.account_ids(scope)

    item_query =
      from item in LibraryItem,
        where:
          not item.hidden and is_nil(item.removed_at) and
            item.provider_account_id in subquery(accessible_account_ids),
        preload: [:provider_account]

    source_query =
      from source in GameSource,
        join: item in assoc(source, :library_items),
        where:
          not item.hidden and is_nil(item.removed_at) and
            item.provider_account_id in subquery(accessible_account_ids),
        distinct: true,
        preload: [library_items: ^item_query]

    cover_query =
      from asset in MediaAsset,
        where: asset.kind == "cover" and asset.cache_status == "ready",
        order_by: [asc: asset.position, asc: asset.id]

    state_query = from state in UserGameState, where: state.user_id == ^user.id

    relation_query =
      from relation in GameCompany,
        where: relation.company_id == ^company_id,
        order_by: [asc: relation.role, asc: relation.id]

    Repo.preload(games, [
      :terms,
      media_assets: cover_query,
      user_states: state_query,
      sources: source_query,
      game_companies: relation_query
    ])
  end
end
