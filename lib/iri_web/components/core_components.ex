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

defmodule IriWeb.CoreComponents do
  @moduledoc "Shared form, navigation, feedback, rating, and icon components."
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="pointer-events-auto w-[min(24rem,calc(100vw-2rem))]"
      {@rest}
    >
      <div class={[
        "flex items-start gap-3 rounded-2xl border p-4 text-sm shadow-2xl backdrop-blur",
        @kind == :info && "border-teal-300/30 bg-slate-900/95 text-teal-50",
        @kind == :error && "border-rose-300/30 bg-slate-900/95 text-rose-50"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label="close">
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any, default: nil
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(
        assigns,
        :base_class,
        "inline-flex min-h-11 items-center justify-center rounded-xl bg-teal-300 px-4 py-2.5 text-sm font-semibold text-on-accent shadow-lg shadow-teal-950/20 transition hover:bg-teal-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-300 disabled:cursor-not-allowed disabled:opacity-50"
      )

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={[@base_class, @class]} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={[@base_class, @class]} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include:
      ~w(accept autocomplete autocapitalize capture cols disabled enterkeyhint form inputmode
                list max maxlength min minlength multiple pattern placeholder readonly required rows
                size spellcheck step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="space-y-2">
      <label for={@id} class="flex cursor-pointer items-center gap-3 text-sm text-slate-200">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && "#{@id}-errors"}
          class={
            @class || "size-4 rounded border-slate-600 bg-slate-900 text-teal-300 focus:ring-teal-300"
          }
          {@rest}
        />
        {@label}
      </label>
      <div :if={@errors != []} id={"#{@id}-errors"} class="space-y-1">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="space-y-2">
      <label for={@id} class="block">
        <span :if={@label} class="mb-2 block text-sm font-medium text-slate-200">{@label}</span>
        <select
          id={@id}
          name={@name}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && "#{@id}-errors"}
          class={[
            @class ||
              "min-h-11 w-full rounded-xl border border-slate-700 bg-slate-900 px-3 py-2.5 text-base text-slate-100 outline-none transition focus:border-teal-300 focus:ring-2 focus:ring-teal-300/20 sm:text-sm",
            "max-sm:text-base",
            @errors != [] &&
              (@error_class || "border-rose-400 focus:border-rose-400 focus:ring-rose-400/20")
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <div :if={@errors != []} id={"#{@id}-errors"} class="space-y-1">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="space-y-2">
      <label for={@id} class="block">
        <span :if={@label} class="mb-2 block text-sm font-medium text-slate-200">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && "#{@id}-errors"}
          class={[
            @class ||
              "min-h-28 w-full rounded-xl border border-slate-700 bg-slate-900 px-3 py-2.5 text-base text-slate-100 outline-none transition placeholder:text-slate-600 focus:border-teal-300 focus:ring-2 focus:ring-teal-300/20 sm:text-sm",
            "max-sm:text-base",
            @errors != [] &&
              (@error_class || "border-rose-400 focus:border-rose-400 focus:ring-rose-400/20")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <div :if={@errors != []} id={"#{@id}-errors"} class="space-y-1">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="space-y-2">
      <label for={@id} class="block">
        <span :if={@label} class="mb-2 block text-sm font-medium text-slate-200">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && "#{@id}-errors"}
          class={[
            @class ||
              "min-h-11 w-full rounded-xl border border-slate-700 bg-slate-900 px-3 py-2.5 text-base text-slate-100 outline-none transition placeholder:text-slate-600 focus:border-teal-300 focus:ring-2 focus:ring-teal-300/20 sm:text-sm",
            "max-sm:text-base",
            @errors != [] &&
              (@error_class || "border-rose-400 focus:border-rose-400 focus:ring-rose-400/20")
          ]}
          {@rest}
        />
      </label>
      <div :if={@errors != []} id={"#{@id}-errors"} class="space-y-1">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  @doc "Renders a search field with a consistent in-field clear control."
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :id, :any, default: nil
  attr :name, :any, default: nil
  attr :value, :any, default: nil
  attr :label, :string, default: nil
  attr :class, :any, default: nil

  attr :rest, :global,
    include:
      ~w(autocomplete autocapitalize autofocus disabled enterkeyhint form inputmode maxlength
         minlength placeholder readonly required spellcheck)

  def search_input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(:field, nil)
    |> assign(:id, assigns.id || field.id)
    |> assign(:name, field.name)
    |> assign(:value, field.value)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> search_input()
  end

  def search_input(assigns) do
    assigns = assign_new(assigns, :errors, fn -> [] end)

    ~H"""
    <div id={"#{@id}-clearable"} phx-hook="ClearableSearch" class="space-y-2">
      <label :if={@label} for={@id} class="block text-sm font-medium text-slate-200">
        {@label}
      </label>
      <div class="relative">
        <input
          type="search"
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value("search", @value)}
          data-clearable-search-input
          enterkeyhint="search"
          inputmode="search"
          autocapitalize="none"
          spellcheck="false"
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && "#{@id}-errors"}
          class={[
            @class ||
              "min-h-11 w-full rounded-xl border border-slate-700 bg-slate-900 px-3 py-2.5 text-base text-slate-100 outline-none transition placeholder:text-slate-600 focus:border-teal-300 focus:ring-2 focus:ring-teal-300/20 sm:text-sm",
            "max-sm:text-base",
            "pr-11 [&::-webkit-search-cancel-button]:hidden [&::-webkit-search-decoration]:hidden",
            @errors != [] && "border-rose-400 focus:border-rose-400 focus:ring-rose-400/20"
          ]}
          {@rest}
        />
        <span class="pointer-events-none absolute inset-y-0 right-1.5 flex items-center">
          <button
            id={"#{@id}-clear"}
            type="button"
            data-clearable-search-button
            disabled={search_blank?(@value)}
            aria-label="Clear search"
            title="Clear search"
            class="pointer-events-auto grid size-8 place-items-center rounded-lg text-slate-500 transition hover:bg-slate-800 hover:text-slate-200 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-teal-300 disabled:pointer-events-none disabled:opacity-0"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </span>
      </div>
      <div :if={@errors != []} id={"#{@id}-errors"} class="space-y-1">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  @doc "Renders a sort select with a separate ascending/descending toggle beside its label."
  attr :field, Phoenix.HTML.FormField, required: true
  attr :id, :any, default: nil
  attr :label, :string, default: "Sort by"
  attr :options, :list, required: true
  attr :direction, :string, required: true, values: ~w(asc desc)
  attr :toggle_event, :string, default: "toggle_sort_direction"
  attr :class, :any, default: nil

  def sort_input(assigns) do
    assigns = assign(assigns, :id, assigns.id || assigns.field.id)

    ~H"""
    <div class="relative">
      <.input
        field={@field}
        id={@id}
        type="select"
        label={@label}
        options={@options}
        class={@class}
      />
      <button
        id={"#{@id}-direction"}
        type="button"
        phx-click={@toggle_event}
        data-sort-direction={@direction}
        aria-label={sort_direction_aria_label(@direction)}
        title={sort_direction_aria_label(@direction)}
        class="absolute -top-1 right-0 inline-flex min-h-7 items-center gap-1 rounded-lg px-1.5 text-xs font-medium text-slate-400 transition hover:bg-slate-800 hover:text-slate-100"
      >
        <.icon
          name={if(@direction == "asc", do: "hero-arrow-up", else: "hero-arrow-down")}
          class="size-3.5"
        />
        {if @direction == "asc", do: "Ascending", else: "Descending"}
      </button>
    </div>
    """
  end

  defp search_blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp sort_direction_aria_label("asc"),
    do: "Sort direction: ascending. Change to descending"

  defp sort_direction_aria_label(_desc),
    do: "Sort direction: descending. Change to ascending"

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-2 text-sm text-rose-300">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-2xl font-semibold leading-8 text-heading">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-slate-400">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc "Renders one face from the five-point personal rating scale."
  attr :rating, :any, required: true
  attr :class, :any, default: "size-5"

  def rating_face(assigns) do
    rating = normalize_rating(assigns.rating)

    assigns =
      assigns
      |> assign(:face, rating_face_index(rating))
      |> assign(:half?, half_rating?(rating))
      |> assign(:rating_value, format_rating_value(rating))

    ~H"""
    <span
      aria-hidden="true"
      class={["relative inline-block shrink-0", @class]}
      data-rating-face={@face}
      data-rating-value={@rating_value}
    >
      <.rating_face_svg face={@face} class={["size-full", @half? && "opacity-30"]} />
      <span :if={@half?} class="absolute inset-y-0 left-0 w-1/2 overflow-hidden">
        <.rating_face_svg face={@face} class="h-full w-[200%] max-w-none" />
      </span>
    </span>
    """
  end

  attr :face, :integer, required: true, values: [1, 2, 3, 4, 5]
  attr :class, :any, required: true

  defp rating_face_svg(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
    >
      <circle cx="12" cy="12" r="10" />
      <%= case @face do %>
        <% 1 -> %>
          <path d="m7.5 8 3 1.5" />
          <path d="m16.5 8-3 1.5" />
          <line x1="9" x2="9.01" y1="12" y2="12" />
          <line x1="15" x2="15.01" y1="12" y2="12" />
          <path d="M8 17c1.25-2.25 6.75-2.25 8 0" />
        <% 2 -> %>
          <path d="M16 16s-1.5-2-4-2-4 2-4 2" />
          <line x1="9" x2="9.01" y1="9" y2="9" />
          <line x1="15" x2="15.01" y1="9" y2="9" />
        <% 3 -> %>
          <line x1="8" x2="16" y1="15" y2="15" />
          <line x1="9" x2="9.01" y1="9" y2="9" />
          <line x1="15" x2="15.01" y1="9" y2="9" />
        <% 4 -> %>
          <path d="M8 14s1.5 2 4 2 4-2 4-2" />
          <line x1="9" x2="9.01" y1="9" y2="9" />
          <line x1="15" x2="15.01" y1="9" y2="9" />
        <% 5 -> %>
          <path d="M18 13a6 6 0 0 1-6 5 6 6 0 0 1-6-5h12Z" />
          <line x1="9" x2="9.01" y1="9" y2="9" />
          <line x1="15" x2="15.01" y1="9" y2="9" />
      <% end %>
    </svg>
    """
  end

  def rating_label(rating) when is_number(rating) do
    case rating_face_index(rating) do
      1 -> "Disgusted"
      2 -> "Disliked"
      3 -> "Meh"
      4 -> "Liked"
      5 -> "Amazing"
    end
  end

  def format_rating_value(rating) when is_integer(rating), do: Integer.to_string(rating)

  def format_rating_value(rating) when is_float(rating) do
    if rating == trunc(rating) do
      rating |> trunc() |> Integer.to_string()
    else
      :erlang.float_to_binary(rating, decimals: 1)
    end
  end

  def rating_face_index(rating) when is_number(rating) do
    rating
    |> ceil()
    |> max(1)
    |> min(5)
  end

  @doc """
  Returns the text color for a rating's place on the red-to-green scale.

  The scale deliberately avoids the accent hue. Each theme remaps the accent,
  so borrowing it for one step made that step collide with a neighbour: orange
  against orange in the dark theme, yellow against yellow in high contrast.
  """
  def rating_tone(rating) do
    case rating_face_index(rating) do
      1 -> "text-rose-200"
      2 -> "text-orange-200"
      3 -> "text-amber-200"
      4 -> "text-lime-200"
      5 -> "text-emerald-200"
    end
  end

  @doc "Returns the border, fill, and text for a selected rating on the same scale."
  def rating_swatch(rating) do
    case rating_face_index(rating) do
      1 -> "border-rose-400/60 bg-rose-400/15 text-rose-200"
      2 -> "border-orange-400/60 bg-orange-400/15 text-orange-200"
      3 -> "border-amber-400/60 bg-amber-400/15 text-amber-200"
      4 -> "border-lime-400/60 bg-lime-400/15 text-lime-200"
      5 -> "border-emerald-400/60 bg-emerald-400/15 text-emerald-200"
    end
  end

  def half_rating?(rating) when is_number(rating), do: rating != trunc(rating)

  defp normalize_rating(rating) when is_number(rating), do: rating
  defp normalize_rating(_rating), do: 3

  @doc """
  Renders a bundled Heroicon. Use `-solid` or `-mini` suffixes for those variants.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc "Interpolates an Ecto validation error for display."
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, message ->
      placeholder = "%{#{key}}"

      if String.contains?(message, placeholder),
        do: String.replace(message, placeholder, to_string(value)),
        else: message
    end)
  end
end
