defmodule TryggWeb.VitalsLive do
  use TryggWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      title="Vitals"
      back={~p"/c/#{@current_child}"}
    >
      <p class="opacity-60 text-sm py-10 text-center">Vitals coming soon.</p>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}
end
