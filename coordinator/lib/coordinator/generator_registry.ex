defmodule Stressgrid.Coordinator.GeneratorRegistry do
  @moduledoc false

  use GenServer
  require Logger

  alias Stressgrid.Coordinator.{
    GeneratorRegistry,
    Utils,
    Reporter,
    GeneratorConnection,
    Management
  }

  defstruct registrations: %{},
            monitors: %{}

  def register(id) do
    GenServer.cast(__MODULE__, {:register, id, self()})
  end

  def start_cohort(id, blocks, addresses) do
    GenServer.cast(__MODULE__, {:start_cohort, id, blocks, addresses})
  end

  def stop_cohort(id) do
    GenServer.cast(__MODULE__, {:stop_cohort, id})
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(_args) do
    :ok = Management.notify_all(%{"generator_count" => 0})
    {:ok, %GeneratorRegistry{}}
  end

  def handle_cast(
        {:register, id, pid},
        %GeneratorRegistry{monitors: monitors, registrations: registrations} = registry
      ) do
    ref = :erlang.monitor(:process, pid)
    Logger.info("Registered generator #{id}")

    registrations = Map.put(registrations, id, pid)

    :ok = Management.notify_all(%{"generator_count" => map_size(registrations)})

    {:noreply,
     %{
       registry
       | registrations: registrations,
         monitors: monitors |> Map.put(ref, id)
     }}
  end

  def handle_cast(
        {:start_cohort, id, blocks, addresses},
        %GeneratorRegistry{registrations: registrations} = registry
      ) do
    :ok =
      registrations
      |> Enum.zip(Utils.split_blocks(blocks, map_size(registrations)))
      |> Enum.each(fn {{_, pid}, blocks} ->
        :ok = GeneratorConnection.start_cohort(pid, id, blocks, addresses)
      end)

    {:noreply, registry}
  end

  def handle_cast(
        {:stop_cohort, id},
        %GeneratorRegistry{registrations: registrations} = registry
      ) do
    :ok =
      registrations
      |> Enum.each(fn {_, pid} ->
        :ok = GeneratorConnection.stop_cohort(pid, id)
      end)

    {:noreply, registry}
  end

  def handle_info(
        {:DOWN, ref, :process, _, reason},
        %GeneratorRegistry{
          monitors: monitors,
          registrations: registrations
        } = registry
      ) do
    case monitors |> Map.get(ref) do
      nil ->
        {:noreply, registry}

      id ->
        Logger.info("Unregistered generator #{id}: #{inspect(reason)}")

        registrations = Map.delete(registrations, id)

        :ok = Management.notify_all(%{"generator_count" => map_size(registrations)})
        :ok = Reporter.clear_stats(id)

        {:noreply,
         %{
           registry
           | registrations: registrations,
             monitors: monitors |> Map.delete(ref)
         }}
    end
  end
end
