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

defmodule Iri.AI.ConfigTest do
  use ExUnit.Case, async: true

  alias Iri.AI.Config

  test "auto-application is the default matching workflow" do
    assert Config.from_options(%{}).mode == :auto
  end

  test "review is the only non-automatic mode" do
    assert Config.from_options(%{mode: "review"}).mode == :review

    assert_raise ArgumentError, ~r/must be auto or review/, fn ->
      Config.from_options(%{mode: "shadow"})
    end
  end

  test "request timeout and retry attempts are internal policies, not configuration" do
    config = Config.from_options(%{timeout_ms: 1, max_attempts: 1})

    refute Map.has_key?(config, :timeout_ms)
    refute Map.has_key?(config, :max_attempts)
  end

  test "missing native credentials disable only AI matching" do
    config = Config.from_options(%{provider: "openai", model: "fixture"})
    assert {:disabled, :api_key_missing} = Config.enabled(config)

    config = Config.from_options(%{provider: "anthropic", api_key: "secret"})
    assert {:disabled, :model_missing} = Config.enabled(config)
  end

  test "an OpenAI-compatible self-hosted endpoint does not require a token" do
    config =
      Config.from_options(%{
        provider: "openai_compatible",
        model: "qwen-fixture",
        base_url: "http://ollama.internal:11434/v1",
        output_format: "json_object"
      })

    assert {:ok, ^config} = Config.enabled(config)
    assert config.api_key == nil
    assert config.output_format == :json_object
  end

  test "invalid compatible URLs are a non-crashing disabled state" do
    config =
      Config.from_options(%{
        provider: "openai_compatible",
        model: "fixture",
        base_url: "not a url"
      })

    assert {:disabled, :invalid_base_url} = Config.enabled(config)
  end
end
