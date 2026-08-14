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

defmodule Iri.Media.PolicyTest do
  use ExUnit.Case, async: false

  alias Iri.Media.{Classification, Policy}
  alias Iri.Accounts.User

  setup do
    previous = Application.get_env(:iri, :nsfw_media)
    on_exit(fn -> Application.put_env(:iri, :nsfw_media, previous) end)
  end

  test "defaults to blurring NSFW media" do
    assert Policy.default_mode() == :blur
  end

  test "applies blur and hide only to games marked as NSFW" do
    Application.put_env(:iri, :nsfw_media, :blur)
    assert Policy.blurred?(%{nsfw: true})
    refute Policy.hidden?(%{nsfw: true})
    refute Policy.restricted?(%{nsfw: false})

    Application.put_env(:iri, :nsfw_media, :hide)
    assert Policy.hidden?(%{nsfw: true})

    Application.put_env(:iri, :nsfw_media, :allow)
    refute Policy.restricted?(%{nsfw: true})
  end

  test "a user's preference overrides or inherits the configured default" do
    Application.put_env(:iri, :nsfw_media, :blur)
    game = %{nsfw: true}

    assert Policy.blurred?(game, %User{sensitive_media_mode: :inherit})
    assert Policy.hidden?(game, %User{sensitive_media_mode: :hide})
    refute Policy.restricted?(game, %User{sensitive_media_mode: :allow})
  end

  test "recognizes already imported IGDB adult terms before the boolean is backfilled" do
    Application.put_env(:iri, :nsfw_media, :blur)

    assert Policy.blurred?(%{
             nsfw: false,
             terms: [%{kind: "theme", name: "Erotic"}]
           })

    refute Policy.blurred?(%{
             nsfw: false,
             terms: [%{kind: "genre", name: "Adventure"}]
           })

    refute Policy.blurred?(%{
             nsfw: false,
             terms: [%{kind: "keyword", name: "Sexual Content"}]
           })

    assert Policy.blurred?(%{
             nsfw: false,
             terms: [],
             sources: [%{nsfw: true}]
           })
  end

  test "a manual non-sensitive override wins over automatic signals" do
    game = %{
      nsfw: true,
      nsfw_override: false,
      terms: [%{name: "Erotic"}],
      sources: [%{nsfw: true}]
    }

    assert Classification.manually_not_sensitive?(game)
    refute Policy.sensitive?(game)
    refute Policy.blurred?(game)
  end

  test "a manual sensitive override wins when providers did not detect it" do
    game = %{
      nsfw: false,
      nsfw_override: true,
      terms: [],
      sources: [%{nsfw: false}]
    }

    assert Policy.sensitive?(game)
    assert Policy.blurred?(game)
  end
end
