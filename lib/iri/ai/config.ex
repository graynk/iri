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

defmodule Iri.AI.Config do
  @moduledoc "Validated, environment-backed AI matching configuration."

  @providers [:disabled, :openai, :anthropic, :openai_compatible]
  @modes [:review, :auto]
  @api_styles [:responses, :chat_completions]
  @output_formats [:json_schema, :json_object, :llama_json_schema, :vllm_structured]

  @type provider :: :disabled | :openai | :anthropic | :openai_compatible
  @type mode :: :review | :auto
  @type api_style :: :responses | :chat_completions
  @type output_format :: :json_schema | :json_object | :llama_json_schema | :vllm_structured

  @type t :: %__MODULE__{
          provider: provider(),
          api_key: String.t() | nil,
          model: String.t() | nil,
          base_url: String.t() | nil,
          mode: mode(),
          api_style: api_style(),
          output_format: output_format()
        }

  defstruct provider: :disabled,
            api_key: nil,
            model: nil,
            base_url: nil,
            mode: :auto,
            api_style: :chat_completions,
            output_format: :json_schema

  def current do
    :iri
    |> Application.get_env(:ai_matching, %{})
    |> from_options()
  end

  def from_options(options) when is_list(options), do: options |> Map.new() |> from_options()

  def from_options(options) when is_map(options) do
    defaults = %__MODULE__{}

    %__MODULE__{
      provider: enum(options[:provider], @providers, defaults.provider),
      api_key: present(options[:api_key]),
      model: present(options[:model]),
      base_url: present(options[:base_url]),
      mode: mode!(options[:mode], defaults.mode),
      api_style: enum(options[:api_style], @api_styles, defaults.api_style),
      output_format: enum(options[:output_format], @output_formats, defaults.output_format)
    }
  end

  def enabled(%__MODULE__{provider: :disabled}), do: {:disabled, :disabled}

  def enabled(%__MODULE__{provider: provider, model: nil}) when provider != :disabled,
    do: {:disabled, :model_missing}

  def enabled(%__MODULE__{provider: provider, api_key: nil})
      when provider in [:openai, :anthropic],
      do: {:disabled, :api_key_missing}

  def enabled(%__MODULE__{provider: :openai_compatible, base_url: nil}),
    do: {:disabled, :base_url_missing}

  def enabled(%__MODULE__{provider: :openai_compatible, base_url: base_url} = config) do
    if valid_base_url?(base_url), do: {:ok, config}, else: {:disabled, :invalid_base_url}
  end

  def enabled(%__MODULE__{} = config), do: {:ok, config}

  def configured?(config \\ current()), do: match?({:ok, _config}, enabled(config))

  def adapter(%__MODULE__{provider: :openai}), do: Iri.AI.OpenAI
  def adapter(%__MODULE__{provider: :anthropic}), do: Iri.AI.Anthropic
  def adapter(%__MODULE__{provider: :openai_compatible}), do: Iri.AI.OpenAICompatible

  defp valid_base_url?(base_url) do
    case URI.parse(base_url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        String.trim(host) != ""

      _url ->
        false
    end
  end

  defp enum(value, allowed, default) when is_atom(value),
    do: if(value in allowed, do: value, else: default)

  defp enum(value, allowed, default) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    Enum.find(allowed, default, &(Atom.to_string(&1) == normalized))
  end

  defp enum(_value, _allowed, default), do: default

  defp mode!(nil, default), do: default

  defp mode!(value, default) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> default
      normalized -> Enum.find(@modes, &(Atom.to_string(&1) == normalized)) || invalid_mode!(value)
    end
  end

  defp mode!(value, _default) when value in @modes, do: value
  defp mode!(value, _default), do: invalid_mode!(value)

  defp invalid_mode!(value) do
    raise ArgumentError, "AI matching mode must be auto or review, got: #{inspect(value)}"
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_value), do: nil
end
