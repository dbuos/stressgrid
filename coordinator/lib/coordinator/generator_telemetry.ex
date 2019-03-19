defmodule Stressgrid.Coordinator.GeneratorTelemetry do
  alias Stressgrid.Coordinator.GeneratorTelemetry

  defstruct cpu: 0.0,
            network_rx: 0,
            network_tx: 0,
            first_script_error: nil,
            active_device_count: 0

  def new(data) do
    %GeneratorTelemetry{
      cpu: data |> Map.get(:cpu, 0.0),
      network_rx: data |> Map.get(:network_rx, 0),
      network_tx: data |> Map.get(:network_tx, 0),
      first_script_error: data |> Map.get(:first_script_error),
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
          first_script_error: first_script_error,
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
    |> add_first_script_error(prefix, first_script_error)
  end

  def to_json(list, prefix) when is_list(list) do
    first_script_error =
      list
      |> Enum.map(fn %GeneratorTelemetry{first_script_error: first_script_error} ->
        first_script_error
      end)
      |> List.first()

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
    |> add_first_script_error(prefix, first_script_error)
  end

  defp add_first_script_error(json, _, nil) do
    json
  end

  defp add_first_script_error(json, prefix, %SyntaxError{description: description, line: line}) do
    json
    |> Map.put("#{prefix}script_error", %{
      "description" => description,
      "line" => line
    })
  end

  defp add_first_script_error(json, prefix, %CompileError{description: description, line: line}) do
    json
    |> Map.put("#{prefix}script_error", %{
      "description" => description,
      "line" => line
    })
  end

  defp add_first_script_error(json, prefix, %TokenMissingError{
         description: description,
         line: line
       }) do
    json
    |> Map.put("#{prefix}script_error", %{
      "description" => description,
      "line" => line
    })
  end
end
