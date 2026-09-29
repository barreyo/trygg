defmodule TryggWeb.SkeletonComponents do
  @moduledoc """
  "Ghost" placeholders shown while a screen's data loads (see
  `TryggWeb.Loading`), and `loadable/1`, which swaps them for the real
  content once it arrives.

  Each screen skeleton mirrors the real layout's boxes and heights, so the
  swap doesn't shove anything around. The skeleton fades in after a short
  delay (`.trygg-skeleton` in app.css): on a quick live navigation the data
  usually lands first and no ghost ever flashes; on a cold start or a slow
  connection it shows up almost immediately.
  """
  use Phoenix.Component

  import TryggWeb.CoreComponents, only: [button: 1, icon: 1]

  @doc """
  Renders `inner_block` once `loaded`, the `skeleton` slot until then, and a
  retry card if the load failed. The retry button pushes `"retry_load"`.

  Wraps the content in a block `div` with the given `id` (the skeleton gets
  `"<id>-loading"`), so the swap is a fresh element that fades in once.
  """
  attr :id, :string, required: true
  attr :loaded, :boolean, required: true
  attr :failed, :boolean, default: false
  attr :label, :string, default: "Loading…", doc: "announced to screen readers while loading"
  attr :class, :any, default: nil, doc: "applied to both the content and the skeleton wrapper"

  attr :retry, :boolean,
    default: true,
    doc:
      "show the retry card on failure; false for a secondary region of a page that already has one"

  slot :skeleton, required: true
  slot :inner_block, required: true

  def loadable(assigns) do
    ~H"""
    <%= cond do %>
      <% @loaded -> %>
        <div id={@id} class={["trygg-reveal", @class]}>{render_slot(@inner_block)}</div>
      <% @failed -> %>
        <div id={"#{@id}-failed"} class={@class}>
          <.load_error :if={@retry} id={"#{@id}-retry"} />
        </div>
      <% true -> %>
        <div
          id={"#{@id}-loading"}
          class={["trygg-skeleton", @class]}
          role="status"
          aria-live="polite"
          aria-busy="true"
        >
          <span class="sr-only">{@label}</span>
          {render_slot(@skeleton)}
        </div>
    <% end %>
    """
  end

  @doc "A single placeholder block. Size and shape it with `class`."
  attr :class, :any, default: nil

  def bone(assigns) do
    ~H"""
    <div class={["skeleton", @class]} aria-hidden="true"></div>
    """
  end

  attr :id, :string, required: true

  defp load_error(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-200/60 px-4 py-8 text-center" role="alert">
      <.icon name="hero-cloud" class="size-8 mx-auto opacity-40" />
      <p class="mt-2 font-medium">This didn't load just now</p>
      <p class="mt-1 text-sm opacity-60">Check the connection, then give it another go.</p>
      <.button
        id={@id}
        type="button"
        variant="primary"
        size="sm"
        class="mt-4"
        phx-click="retry_load"
        phx-disable-with="Loading…"
      >
        <.icon name="hero-arrow-path" class="size-4" /> Try again
      </.button>
    </div>
    """
  end

  ## Shared pieces --------------------------------------------------------

  @doc "Log rows, shaped like `TryggWeb.LogComponents.entry_row/1`."
  attr :count, :integer, default: 6
  attr :show_date, :boolean, default: false

  def entry_rows_skeleton(assigns) do
    ~H"""
    <div class="divide-y divide-base-300">
      <div :for={i <- 1..@count} class="py-3 flex items-center gap-3">
        <.bone class="size-9 rounded-full shrink-0" />
        <div class="flex-1 min-w-0 space-y-1.5">
          <.bone class={["h-4 rounded", row_width(i)]} />
          <.bone class="h-3 w-1/4 rounded" />
        </div>
        <div class="shrink-0 flex flex-col items-end gap-1.5">
          <.bone class={["h-4 rounded", if(@show_date, do: "w-24", else: "w-12")]} />
          <.bone class="h-3 w-10 rounded" />
        </div>
      </div>
    </div>
    """
  end

  # Vary the title widths a little so the list reads as rows of text, not a
  # barcode.
  defp row_width(i), do: Enum.at(~w(w-2/5 w-1/2 w-1/3 w-3/5), rem(i, 4))

  @doc "A glance/stat card, shaped like `TryggWeb.LogComponents.since_card/1`."
  attr :class, :any, default: nil
  attr :today, :boolean, default: false, doc: "include the small \"today\" line"

  def stat_card_skeleton(assigns) do
    ~H"""
    <div class={["rounded-box bg-base-200/70 p-2 flex flex-col gap-1.5 min-w-0", @class]}>
      <.bone class="h-3 w-3/5 rounded" />
      <.bone class="h-6 w-4/5 rounded mt-0.5" />
      <.bone class="h-3 w-full rounded" />
      <.bone :if={@today} class="h-2.5 w-2/3 rounded mt-auto" />
    </div>
    """
  end

  ## Screens --------------------------------------------------------------

  @doc "Home: the at-a-glance cards and the quick-log buttons."
  attr :can_write, :boolean, default: true

  def home_status_skeleton(assigns) do
    ~H"""
    <section class="bg-base-200/40 rounded-box p-2">
      <div class="grid grid-cols-3 gap-2">
        <.stat_card_skeleton :for={_ <- 1..3} class="h-36" today />
      </div>
    </section>

    <div :if={@can_write} class="mt-6 rounded-box bg-base-200/40 p-3 space-y-3">
      <.bone class="h-12 w-full rounded-field" />
      <.bone class="h-12 w-full rounded-field" />
      <div>
        <.bone class="h-3 w-12 rounded mb-2" />
        <div class="grid grid-cols-3 gap-2">
          <.bone :for={_ <- 1..3} class="h-[4.5rem] rounded-field" />
        </div>
      </div>
      <.bone class="h-8 w-40 mx-auto rounded-field" />
    </div>
    """
  end

  @doc "Vitals: latest stats, weight gain, growth charts and history."
  attr :can_write, :boolean, default: true

  def vitals_skeleton(assigns) do
    ~H"""
    <div class="md:grid md:grid-cols-2 md:grid-rows-[auto_1fr] md:items-start md:gap-x-6">
      <div class="md:col-start-1 min-w-0">
        <section class="rounded-box border border-base-300 bg-base-200/40 p-2">
          <div class="grid grid-cols-2 gap-2">
            <.stat_card_skeleton :for={_ <- 1..2} class="h-24" />
          </div>
        </section>

        <section class="mt-4 rounded-box border border-base-300 overflow-hidden">
          <div class="bg-base-200/40 px-3 py-2.5 flex justify-between">
            <.bone class="h-4 w-24 rounded" />
            <.bone class="h-3 w-20 rounded" />
          </div>
          <div class="p-3 space-y-2">
            <.bone class="h-6 w-2/5 rounded" />
            <.bone class="h-3 w-4/5 rounded" />
          </div>
        </section>

        <.bone :if={@can_write} class="mt-4 h-12 w-full rounded-field" />
      </div>

      <section class="mt-6 md:mt-0 md:col-start-2 md:row-span-2 md:row-start-1 min-w-0 rounded-box border border-base-300 overflow-hidden">
        <div class="bg-base-200/40 px-3 pt-3 pb-3 space-y-3">
          <div class="flex items-start justify-between gap-2">
            <div class="space-y-1.5">
              <.bone class="h-4 w-16 rounded" />
              <.bone class="h-3 w-28 rounded" />
            </div>
            <div class="flex gap-2">
              <.bone class="size-11 rounded-field" />
              <.bone class="size-11 rounded-field" />
            </div>
          </div>
          <.bone class="h-9 w-full rounded-field" />
        </div>
        <div class="divide-y divide-base-300">
          <div :for={_ <- 1..2} class="p-3 space-y-2">
            <.bone class="h-4 w-20 rounded" />
            <.bone class="h-44 w-full rounded-box" />
          </div>
        </div>
      </section>

      <section class="mt-6 md:col-start-1 min-w-0 rounded-box border border-base-300 overflow-hidden">
        <div class="px-3 py-2.5 border-b border-base-300 bg-base-200/40">
          <.bone class="h-4 w-16 rounded" />
        </div>
        <div class="divide-y divide-base-300">
          <div :for={_ <- 1..4} class="h-12 px-3 flex items-center gap-4">
            <.bone class="h-3.5 w-16 rounded" />
            <.bone class="h-3.5 w-14 rounded" />
            <.bone class="h-3.5 w-14 rounded" />
            <.bone class="h-3.5 w-10 rounded ml-auto" />
          </div>
        </div>
      </section>
    </div>
    """
  end

  @doc "Reports: the body of the Today / 7 days / Trends view."
  attr :view, :atom, required: true

  def report_skeleton(%{view: :trends} = assigns) do
    ~H"""
    <div class="mt-4 md:grid md:grid-cols-2 md:items-start md:gap-6">
      <div class="min-w-0 space-y-6">
        <div class="rounded-box border border-base-300 p-3 space-y-2">
          <.bone class="h-4 w-28 rounded" />
          <.bone class="h-5 w-3/5 rounded" />
          <.bone class="h-3 w-4/5 rounded" />
        </div>
        <div :for={_ <- 1..2} class="rounded-box border border-base-300 p-3 space-y-3">
          <.bone class="h-4 w-24 rounded" />
          <.bone class="h-28 w-full rounded-box" />
        </div>
      </div>
      <div class="mt-6 md:mt-0 min-w-0 space-y-3">
        <div class="flex items-center justify-between">
          <.bone class="h-5 w-20 rounded" />
          <.bone class="h-4 w-32 rounded" />
        </div>
        <div class="grid grid-cols-2 gap-2">
          <.stat_card_skeleton :for={_ <- 1..4} class="h-24" />
        </div>
        <.bone class="h-48 w-full rounded-box" />
      </div>
    </div>
    """
  end

  def report_skeleton(assigns) do
    ~H"""
    <div class="mt-4 md:grid md:grid-cols-2 md:items-start md:gap-6">
      <div class="min-w-0">
        <div class="flex items-center justify-between gap-2 mb-2">
          <.bone :if={@view == :today} class="size-11 rounded-field" />
          <.bone class={["h-5 w-32 rounded", @view == :today && "mx-auto"]} />
          <.bone :if={@view == :today} class="size-11 rounded-field" />
        </div>
        <div class="grid grid-cols-2 gap-2 mb-4">
          <.stat_card_skeleton :for={_ <- 1..2} class="h-24" />
        </div>
      </div>
      <div class="min-w-0">
        <div class="md:max-w-sm md:mx-auto">
          <.bone class="aspect-square w-full rounded-box" />
          <.bone class="h-3 w-32 rounded mx-auto mt-3" />
        </div>
      </div>
    </div>
    """
  end

  @doc "Sharing: the caregiver list."
  attr :count, :integer, default: 2

  def member_rows_skeleton(assigns) do
    ~H"""
    <ul class="mt-4 divide-y divide-base-300 rounded-box border border-base-300 bg-base-200">
      <li :for={_ <- 1..@count} class="flex items-center gap-3 p-3">
        <.bone class="size-9 rounded-full shrink-0" />
        <div class="flex-1 min-w-0 space-y-1.5">
          <.bone class="h-4 w-1/2 rounded" />
          <.bone class="h-3 w-16 rounded" />
        </div>
      </li>
    </ul>
    """
  end

  @doc "Children: the list of child cards."
  attr :count, :integer, default: 2

  def child_cards_skeleton(assigns) do
    ~H"""
    <ul class="space-y-3">
      <li
        :for={_ <- 1..@count}
        class="flex items-center gap-3 p-4 rounded-box border border-base-300 bg-base-200"
      >
        <.bone class="size-11 rounded-full shrink-0" />
        <div class="flex-1 min-w-0 space-y-1.5">
          <.bone class="h-4 w-2/5 rounded" />
          <.bone class="h-3.5 w-1/4 rounded" />
        </div>
        <.bone class="h-5 w-14 rounded-full" />
      </li>
    </ul>
    """
  end
end
