defmodule TryggWeb.ReportsLive do
  use TryggWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      children={@children}
      child_switch_to={:reports}
      title="Reports"
      back={~p"/c/#{@current_child}"}
    >
      <p class="opacity-60 text-sm py-10 text-center">Reports coming soon.</p>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}
end
