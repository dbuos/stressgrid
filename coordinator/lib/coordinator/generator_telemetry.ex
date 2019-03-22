defmodule Stressgrid.Coordinator.GeneratorTelemetry do
  alias Stressgrid.Coordinator.GeneratorTelemetry

  defstruct cpu: 0.0,
            network_rx: 0,
            network_tx: 0,
            active_device_count: 0

  def new(data) do
    %GeneratorTelemetry{
      cpu: data |> Map.get(:cpu, 0.0),
      network_rx: data |> Map.get(:network_rx, 0),
      network_tx: data |> Map.get(:network_tx, 0),
      active_device_count: data |> Map.get(:active_device_count, 0)
    }
  end

  def to_json(telemetry, prefix \\ "")

  def to_json(nil, _) do
    %{}
  end

  def to_json(
        %GeneratorTelemetry{
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

  def to_json(list, prefix) when is_list(list) do
    %{
      "#{prefix}cpu" => list |> Enum.map(fn %GeneratorTelemetry{cpu: cpu} -> cpu end),
      "#{prefix}network_rx" =>
        list |> Enum.map(fn %GeneratorTelemetry{network_rx: network_rx} -> network_rx end),
      "#{prefix}network_tx" =>
        list |> Enum.map(fn %GeneratorTelemetry{network_tx: network_tx} -> network_tx end),
      "#{prefix}active_count" =>
        list
        |> Enum.map(fn %GeneratorTelemetry{active_device_count: active_device_count} ->
          active_device_count
        end)
    }
  end
end
