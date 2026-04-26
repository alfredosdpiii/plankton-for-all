defmodule MyAppWeb.OrderLive do
  use MyAppWeb, :live_view

  alias MyApp.Orders

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(MyApp.PubSub, "orders")
    {:ok, stream(socket, :orders, Orders.list_orders())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    Orders.delete_order(id)
    {:noreply, stream_delete(socket, :orders, %{id: id})}
  end

  @impl true
  def handle_info({:order_created, order}, socket) do
    {:noreply, stream_insert(socket, :orders, order)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div id="orders" phx-update="stream">
        <div :for={{dom_id, order} <- @streams.orders} id={dom_id}>
          <p><%= order.name %></p>
          <button phx-click="delete" phx-value-id={order.id}>Delete</button>
        </div>
      </div>
    </div>
    """
  end
end
