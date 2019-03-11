defmodule Stressgrid.Coordinator.Reporter do
  use GenServer

  alias Stressgrid.Coordinator.{Reporter, ManagementConnection, GeneratorTelemetry}

  defstruct writer_configs: [],
            generator_telemetries: %{},
            aggregated_telemetries: [],
            aggregated_generator_counts: [],
            runs: %{},
            reports: %{}

  @report_interval 60_000
  @notify_interval 1_000
  @aggregated_max_size 60

  defmodule Run do
    defstruct name: nil,
              clock: 0,
              hists: %{},
              counters: %{},
              prev_counters: %{},
              max_telemetry: nil,
              writers: []
  end

  defmodule Report do
    defstruct name: nil,
              max_telemetry: nil,
              result_json: %{}
  end

  def report_to_json(id, %Report{
        name: name,
        result_json: result_json,
        max_telemetry: max_telemetry
      }) do
    %{
      "id" => id,
      "name" => name,
      "result" => result_json
    }
    |> Map.merge(max_telemetry |> GeneratorTelemetry.to_json("max_"))
  end

  def push_telemetry(generator_id, telemetry) do
    GenServer.cast(
      __MODULE__,
      {:push_telemetry, generator_id, telemetry}
    )
  end

  def start_run(id, name) do
    GenServer.cast(__MODULE__, {:start_run, id, name})
  end

  def stop_run(id) do
    GenServer.cast(__MODULE__, {:stop_run, id})
  end

  def remove_report(id) do
    GenServer.cast(__MODULE__, {:remove_report, id})
  end

  def clear_stats(conn_id) do
    GenServer.cast(__MODULE__, {:clear_stats, conn_id})
  end

  def get_reports_json() do
    GenServer.call(__MODULE__, :get_reports_json)
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(args) do
    Process.send_after(self(), :notify, @notify_interval)

    {:ok, %Reporter{writer_configs: args |> Keyword.get(:writer_configs, [])}}
  end

  def handle_call(:get_reports_json, _, %Reporter{reports: reports} = reporter) do
    reports_json =
      reports
      |> Enum.map(fn {id, report} ->
        report_to_json(id, report)
      end)

    {:reply, {:ok, reports_json}, reporter}
  end

  def handle_cast(
        {:push_telemetry, generator_id, telemetry},
        %Reporter{
          generator_telemetries: generator_telemetries,
          runs: runs
        } = reporter
      ) do
    %{counters: push_counters, hists: push_hists} = telemetry

    generator_telemetries =
      generator_telemetries
      |> Map.put(generator_id, GeneratorTelemetry.new(telemetry))

    max_telemetry =
      generator_telemetries
      |> Map.values()
      |> Enum.reduce(nil, &max_telemetry(&1, &2))

    runs =
      runs
      |> Enum.map(fn {id,
                      %Run{counters: counters, hists: hists, max_telemetry: max_telemetry0} = run} ->
        counters =
          push_counters
          |> Enum.reduce(counters, fn {key, value}, counters ->
            counters
            |> Map.update(key, value, fn c -> c + value end)
          end)

        hists =
          push_hists
          |> Enum.reduce(hists, fn {key, push_hist}, hists ->
            {:ok, hist} = :hdr_histogram.from_binary(push_hist)

            hists
            |> Map.update(key, hist, fn hist0 ->
              :hdr_histogram.add(hist0, hist)
              :hdr_histogram.close(hist)
              hist0
            end)
          end)

        {id,
         %{
           run
           | hists: hists,
             counters: counters,
             max_telemetry: max_telemetry(max_telemetry, max_telemetry0)
         }}
      end)
      |> Map.new()

    {:noreply,
     %{
       reporter
       | generator_telemetries: generator_telemetries,
         runs: runs
     }}
  end

  def handle_cast(
        {:start_run, id, name},
        %Reporter{runs: runs, writer_configs: writer_configs} = reporter
      ) do
    writers =
      writer_configs
      |> Enum.map(fn {module, params} ->
        Kernel.apply(module, :init, params)
      end)

    send(self(), {:report, id})

    {:noreply, %{reporter | runs: runs |> Map.put(id, %Run{name: name, writers: writers})}}
  end

  def handle_cast(
        {:stop_run, id},
        %Reporter{runs: runs, reports: reports, writer_configs: writer_configs} = reporter
      ) do
    case runs |> Map.get(id) do
      %Run{name: name, max_telemetry: max_telemetry, writers: writers} ->
        result_json =
          Enum.zip(writer_configs, writers)
          |> Enum.reduce(%{}, fn {{module, _}, writer}, r ->
            Kernel.apply(module, :finish, [r, id, writer])
          end)

        report = %Report{name: name, max_telemetry: max_telemetry, result_json: result_json}

        :ok = ManagementConnection.notify(%{"report_added" => report_to_json(id, report)})

        {:noreply,
         %{
           reporter
           | runs: runs |> Map.delete(id),
             reports: reports |> Map.put(id, report)
         }}

      nil ->
        {:noreply, reporter}
    end
  end

  def handle_cast(
        {:clear_stats, conn_id},
        %Reporter{
          generator_telemetries: generator_telemetries
        } = reporter
      ) do
    generator_telemetries =
      generator_telemetries
      |> Map.delete(conn_id)

    {:noreply,
     %{
       reporter
       | generator_telemetries: generator_telemetries
     }}
  end

  def handle_cast(
        {:remove_report, id},
        %Reporter{reports: reports} = reporter
      ) do
    case reports |> Map.get(id) do
      %Report{} ->
        :ok = ManagementConnection.notify(%{"report_removed" => %{"id" => id}})

        {:noreply,
         %{
           reporter
           | reports: reports |> Map.delete(id)
         }}

      nil ->
        {:noreply, reporter}
    end
  end

  def handle_info(
        {:report, id},
        %Reporter{
          writer_configs: writer_configs,
          generator_telemetries: generator_telemetries,
          runs: runs
        } = reporter
      ) do
    case runs |> Map.get(id) do
      %Run{
        clock: clock,
        counters: counters,
        prev_counters: prev_counters,
        hists: hists,
        writers: writers
      } = run ->
        Process.send_after(self(), {:report, id}, @report_interval)

        rates =
          prev_counters
          |> Enum.map(fn {key, prev_value} ->
            value =
              counters
              |> Map.get(key)

            {"#{key}_per_second" |> String.to_atom(),
             (value - prev_value) / (@report_interval / 1_000)}
          end)
          |> Map.new()

        scalars =
          counters
          |> Map.merge(rates)

        writers =
          Enum.zip(writer_configs, writers)
          |> Enum.map(fn {{module, _}, writer} ->
            writer = Kernel.apply(module, :write_hists, [id, clock, writer, hists])
            writer = Kernel.apply(module, :write_scalars, [id, clock, writer, scalars])

            Kernel.apply(module, :write_generator_telemetries, [
              id,
              clock,
              writer,
              generator_telemetries |> Map.to_list()
            ])
          end)

        hists
        |> Enum.each(fn {_, hist} ->
          :ok = :hdr_histogram.reset(hist)
        end)

        run = %{run | clock: clock + 1, prev_counters: counters, hists: hists, writers: writers}

        {:noreply, %{reporter | runs: runs |> Map.put(id, run)}}

      nil ->
        {:noreply, %{reporter | runs: runs}}
    end
  end

  def handle_info(
        :notify,
        %Reporter{
          generator_telemetries: generator_telemetries,
          aggregated_telemetries: aggregated_telemetries,
          aggregated_generator_counts: aggregated_generator_counts
        } = reporter
      ) do
    Process.send_after(self(), :notify, @notify_interval)

    aggregated_telemetry =
      generator_telemetries
      |> Map.values()
      |> aggregate_telemetries()

    aggregated_telemetries =
      [aggregated_telemetry | aggregated_telemetries]
      |> Enum.take(@aggregated_max_size)

    aggregated_generator_counts =
      [Map.size(generator_telemetries) | aggregated_generator_counts]
      |> Enum.take(@aggregated_max_size)

    :ok =
      ManagementConnection.notify(%{
        "grid_changed" =>
          %{
            "recent_generator_count" => aggregated_generator_counts
          }
          |> Map.merge(aggregated_telemetries |> GeneratorTelemetry.to_json("recent_"))
      })

    {:noreply,
     %{
       reporter
       | aggregated_telemetries: aggregated_telemetries,
         aggregated_generator_counts: aggregated_generator_counts
     }}
  end

  defp max_telemetry(nil, _) do
    nil
  end

  defp max_telemetry(generator_telemetry, nil) do
    generator_telemetry
  end

  defp max_telemetry(
         %GeneratorTelemetry{
           cpu: cpu0,
           network_rx: network_rx0,
           network_tx: network_tx0,
           active_device_count: active_device_count0
         },
         %GeneratorTelemetry{
           cpu: cpu1,
           network_rx: network_rx1,
           network_tx: network_tx1,
           active_device_count: active_device_count1
         }
       ) do
    %GeneratorTelemetry{
      cpu: max(cpu0, cpu1),
      network_rx: max(network_rx0, network_rx1),
      network_tx: max(network_tx0, network_tx1),
      active_device_count: max(active_device_count0, active_device_count1)
    }
  end

  defp aggregate_telemetries(telemetries) do
    telemetries_length = length(telemetries)

    %GeneratorTelemetry{
      cpu:
        if(telemetries_length === 0,
          do: 0.0,
          else: telemetries |> Enum.map(fn %GeneratorTelemetry{cpu: cpu} -> cpu end) |> Enum.max()
        ),
      network_rx:
        telemetries
        |> Enum.map(fn %GeneratorTelemetry{network_rx: network_rx} -> network_rx end)
        |> Enum.sum(),
      network_tx:
        telemetries
        |> Enum.map(fn %GeneratorTelemetry{network_tx: network_tx} -> network_tx end)
        |> Enum.sum(),
      active_device_count:
        telemetries
        |> Enum.map(fn %GeneratorTelemetry{active_device_count: active_device_count} ->
          active_device_count
        end)
        |> Enum.sum()
    }
  end
end
