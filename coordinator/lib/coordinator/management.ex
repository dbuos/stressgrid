defmodule Stressgrid.Coordinator.Management do
  use GenServer

  alias Stressgrid.Coordinator.{Management}

  defstruct last_notify_json: %{}

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(_) do
    {:ok, %Management{}}
  end

  def registry_spec do
    {Registry, keys: :duplicate, name: :management_connection_registry}
  end

  def connect() do
    Registry.register(:management_connection_registry, nil, nil)
    GenServer.cast(__MODULE__, {:init_connection, self()})
  end

  def notify_all(json) do
    GenServer.cast(__MODULE__, {:notify_all, json})
  end

  def handle_cast(
        {:notify_all, json},
        %Management{last_notify_json: last_notify_json} = management
      ) do
    Enum.each(Registry.lookup(:management_connection_registry, nil), fn {pid, nil} ->
      _ = send(pid, {:send, :notify, json})
    end)

    last_notify_json = Map.merge(last_notify_json, json)

    {:noreply, %{management | last_notify_json: last_notify_json}}
  end

  def handle_cast(
        {:init_connection, pid},
        %Management{last_notify_json: last_notify_json} = management
      ) do
    _ = send(pid, {:send, :init, last_notify_json})

    {:noreply, management}
  end
end
