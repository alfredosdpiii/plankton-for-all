defmodule MyAppWeb.OrderLive do
  use MyAppWeb, :live_view

  alias MyApp.Repo
  alias MyApp.Order

  def mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "orders")
    orders = Repo.all(Order)
    {:ok, assign(socket, :orders, Enum.map(orders, &Map.from_struct/1))}
  end

  def handle_event("delete", params, socket) do
    id = params["id"]
    Repo.delete!(Repo.get!(Order, id))
    {:noreply, assign(socket, :orders, Repo.all(Order))}
  end

  def handle_info({:order_created, order}, socket) do
    {:noreply, update(socket, :orders, fn orders -> [order | orders] end)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <%= for order <- @orders do %>
        <p><%= order.name %></p>
        <button phx-click="delete" phx-value-id={order.id}>Delete</button>
      <% end %>
    </div>
    """
  end
end
