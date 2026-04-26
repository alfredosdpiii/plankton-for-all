defmodule MyAppWeb.DashboardLive do
  use MyAppWeb, :live_view

  alias MyApp.Stats

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(MyApp.PubSub, "stats")
    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:user_count, Stats.user_count())
     |> assign(:debug_data, Stats.debug_info())
     |> assign(:revenue, Stats.total_revenue())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1><%= @page_title %></h1>
      <p>Users: <%= @user_count %></p>
    </div>
    """
  end
end
