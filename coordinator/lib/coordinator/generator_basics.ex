defmodule Stressgrid.Coordinator.GeneratorBasics do
  alias Stressgrid.Coordinator.GeneratorBasics

  defstruct cpu: 0.0,
            network_rx: 0,
            network_tx: 0,
            active_device_count: 0

  def new(data) do
    %GeneratorBasics{
      cpu: data |> Map.get(:cpu, 0.0),
      network_rx: data |> Map.get(:network_rx, 0),
      network_tx: data |> Map.get(:network_tx, 0),
      active_device_count: data |> Map.get(:active_device_count, 0)
    }
  end

  def to_json(basics, prefix \\ "")

  def to_json(nil, _) do
    %{}
  end

  def to_json(
        %GeneratorBasics{
          cpu: cpu,
          network_rx: network_rx,
          network_tx: network_tx,
          active_device_count: active_device_count
        },
        prefix
      ) do
    %{
      "#{prefix}cpu" => cpu,
      "#{prefix}network_rx" => network_rx,
      "#{prefix}network_tx" => network_tx,
      "#{prefix}active_count" => active_device_count
    }
  end
end
