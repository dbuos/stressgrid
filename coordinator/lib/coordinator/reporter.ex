defmodule Stressgrid.Coordinator.Reporter do
  use GenServer

  alias Stressgrid.Coordinator.{Reporter, ManagementConnection, GeneratorTelemetry}

  defstruct writer_configs: [],
            run: nil,
            generator_telemetries: %{},
            last_script_error: nil,
            last_errors: %{},
            aggregated_telemetries: [],
            aggregated_generator_counts: [],
            aggregated_last_errors: %{},
            reports: %{}

  @report_interval 60_000
  @aggregate_interval 1_000
  @aggregated_max_size 60

  defmodule Run do
    defstruct id: nil,
              plan_name: nil,
              clock: 0,
              hists: %{},
              counters: %{},
              prev_counters: %{},
              max_telemetry: nil,
              writers: [],
              report_timer_ref: nil
  end

  defmodule Report do
    defstruct script_error: nil,
              errors: nil,
              plan_name: nil,
              max_telemetry: nil,
              result_json: %{}
  end

  def push_telemetry(generator_id, telemetry) do
    GenServer.cast(
      __MODULE__,
      {:push_telemetry, generator_id, telemetry}
    )
  end

  def start_run(id, plan_name) do
    GenServer.cast(__MODULE__, {:start_run, id, plan_name})
  end

  def stop_run do
    GenServer.cast(__MODULE__, :stop_run)
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

  def get_telemetry_json() do
    GenServer.call(__MODULE__, :get_telemetry_json)
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(args) do
    Process.send_after(self(), :aggregate, @aggregate_interval)

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

  def handle_call(
        :get_telemetry_json,
        _,
        %Reporter{
          last_script_error: last_script_error,
          aggregated_generator_counts: aggregated_generator_counts,
          aggregated_telemetries: aggregated_telemetries,
          aggregated_last_errors: aggregated_last_errors
        } = reporter
      ) do
    telemetry_json =
      %{
        "generator_count" => aggregated_generator_counts
      }
      |> add_script_error("last_script_error", last_script_error)
      |> add_errors("last_errors", aggregated_last_errors)
      |> Map.merge(aggregated_telemetries |> GeneratorTelemetry.to_json())

    {:reply, {:ok, telemetry_json}, reporter}
  end

  def handle_cast(
        {:push_telemetry, generator_id, telemetry},
        %Reporter{
          generator_telemetries: generator_telemetries,
          run: run,
          last_errors: last_errors,
          last_script_error: last_script_error
        } = reporter
      ) do
    %{counters: push_counters, hists: push_hists, first_script_error: first_script_error} =
      telemetry

    generator_telemetries =
      generator_telemetries
      |> Map.put(generator_id, GeneratorTelemetry.new(telemetry))

    max_telemetry =
      generator_telemetries
      |> Map.values()
      |> Enum.reduce(nil, &max_telemetry(&1, &2))

    last_errors =
      push_counters
      |> Enum.reduce(last_errors, fn {key, value}, last_errors ->
        case ~r/(.*)_error_count$/ |> Regex.run(key |> Atom.to_string()) do
          [_, type] ->
            type = type |> String.to_atom()
            count = last_errors |> Map.get(type, 0)
            last_errors |> Map.put(type, count + value)

          nil ->
            last_errors
        end
      end)

    run =
      case run do
        %Run{counters: counters, hists: hists, max_telemetry: max_telemetry0} = run ->
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

          %{
            run
            | hists: hists,
              counters: counters,
              max_telemetry: max_telemetry(max_telemetry, max_telemetry0)
          }

        nil ->
          nil
      end

    {:noreply,
     %{
       reporter
       | generator_telemetries: generator_telemetries,
         run: run,
         last_errors: last_errors,
         last_script_error:
           if(first_script_error != nil, do: first_script_error, else: last_script_error)
     }}
  end

  def handle_cast(
        {:start_run, id, plan_name},
        %Reporter{writer_configs: writer_configs} = reporter
      ) do
    writers =
      writer_configs
      |> Enum.map(fn {module, params} ->
        Kernel.apply(module, :init, params)
      end)

    send(self(), :report)

    {:noreply,
     %{
       reporter
       | run: %Run{id: id, plan_name: plan_name, writers: writers},
         last_script_error: nil,
         last_errors: %{},
         aggregated_last_errors: %{}
     }}
  end

  def handle_cast(
        :stop_run,
        %Reporter{
          run: run,
          last_script_error: last_script_error,
          last_errors: last_errors,
          reports: reports,
          writer_configs: writer_configs
        } = reporter
      ) do
    case run do
      %Run{
        id: id,
        plan_name: plan_name,
        max_telemetry: max_telemetry,
        writers: writers,
        report_timer_ref: report_timer_ref
      } ->
        result_json =
          Enum.zip(writer_configs, writers)
          |> Enum.reduce(%{}, fn {{module, _}, writer}, r ->
            Kernel.apply(module, :finish, [r, id, writer])
          end)

        report = %Report{
          script_error: last_script_error,
          errors: last_errors,
          plan_name: plan_name,
          max_telemetry: max_telemetry,
          result_json: result_json
        }

        :ok = ManagementConnection.notify(%{"report_added" => report_to_json(id, report)})

        if report_timer_ref !== nil do
          Process.cancel_timer(report_timer_ref)
        end

        {:noreply,
         %{
           reporter
           | run: nil,
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
        :report,
        %Reporter{
          writer_configs: writer_configs,
          generator_telemetries: generator_telemetries,
          run: run
        } = reporter
      ) do
    case run do
      %Run{
        id: id,
        clock: clock,
        counters: counters,
        prev_counters: prev_counters,
        hists: hists,
        writers: writers
      } = run ->
        report_timer_ref = Process.send_after(self(), :report, @report_interval)

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

        run = %{
          run
          | clock: clock + 1,
            prev_counters: counters,
            hists: hists,
            writers: writers,
            report_timer_ref: report_timer_ref
        }

        {:noreply, %{reporter | run: run}}

      nil ->
        {:noreply, reporter}
    end
  end

  def handle_info(
        :aggregate,
        %Reporter{
          generator_telemetries: generator_telemetries,
          last_errors: last_errors,
          aggregated_telemetries: aggregated_telemetries,
          aggregated_generator_counts: aggregated_generator_counts,
          aggregated_last_errors: aggregated_last_errors
        } = reporter
      ) do
    Process.send_after(self(), :aggregate, @aggregate_interval)

    aggregated_telemetry =
      generator_telemetries
      |> Map.values()
      |> aggregate_telemetries()

    aggregated_telemetries =
      [aggregated_telemetry | aggregated_telemetries]
      |> Enum.take(@aggregated_max_size)

    aggregated_generator_counts =
      [map_size(generator_telemetries) | aggregated_generator_counts]
      |> Enum.take(@aggregated_max_size)

    aggregated_last_errors =
      last_errors
      |> Enum.reduce(aggregated_last_errors, fn {type, count}, aggregated_last_errors ->
        aggregated_last_errors
        |> Map.update(type, [count], &([count | &1] |> Enum.take(@aggregated_max_size)))
      end)

    {:noreply,
     %{
       reporter
       | aggregated_telemetries: aggregated_telemetries,
         aggregated_generator_counts: aggregated_generator_counts,
         aggregated_last_errors: aggregated_last_errors
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

  defp report_to_json(id, %Report{
         script_error: script_error,
         errors: errors,
         plan_name: plan_name,
         result_json: result_json,
         max_telemetry: max_telemetry
       }) do
    %{
      "id" => id,
      "name" => plan_name,
      "result" => result_json
    }
    |> add_script_error("script_error", script_error)
    |> add_errors("errors", errors)
    |> Map.merge(max_telemetry |> GeneratorTelemetry.to_json("max_"))
  end

  defp add_script_error(json, _, nil) do
    json
  end

  defp add_script_error(json, name, %{
         script: script,
         error: %SyntaxError{description: description, line: line}
       }) do
    json
    |> Map.put(name, %{
      "script" => script,
      "description" => description,
      "line" => line
    })
  end

  defp add_script_error(json, name, %{
         script: script,
         error: %CompileError{description: description, line: line}
       }) do
    json
    |> Map.put(name, %{
      "script" => script,
      "description" => description,
      "line" => line
    })
  end

  defp add_script_error(json, name, %{
         script: script,
         error: %TokenMissingError{
           description: description,
           line: line
         }
       }) do
    json
    |> Map.put(name, %{
      "script" => script,
      "description" => description,
      "line" => line
    })
  end

  defp add_errors(json, _, errors) when map_size(errors) === 0 do
    json
  end

  defp add_errors(json, name, errors) do
    json
    |> Map.put(name, errors)
  end
end
