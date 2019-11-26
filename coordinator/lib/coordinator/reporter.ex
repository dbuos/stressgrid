defmodule Stressgrid.Coordinator.Reporter do
  use GenServer

  alias Stressgrid.Coordinator.{Reporter, Management, Histogram}

  defstruct writer_configs: [],
            run: nil,
            reports: []

  defmodule Run do
    defstruct id: nil,
              plan_name: nil,
              counters: %{},
              generator_totals: %{},
              maximums: %{},
              last_script_error: nil,
              writers: %{}
  end

  defmodule Report do
    defstruct id: nil,
              plan_name: nil,
              maximums: nil,
              script_error: nil,
              result_json: %{}
  end

  defmodule Writer do
    defstruct module: nil,
              interval_ms: nil,
              state: nil,
              timer_ref: nil,
              clock: 0,
              hists: %{},
              prev_counters: %{}
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

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(args) do
    {:ok, %Reporter{writer_configs: args |> Keyword.get(:writer_configs, [])}}
  end

  def handle_cast(
        {:push_telemetry, generator_id, telemetry},
        %Reporter{run: run} = reporter
      ) do
    %{scalars: push_scalars, hists: push_binary_hists, first_script_error: first_script_error} =
      telemetry

    run =
      case run do
        %Run{
          counters: counters,
          generator_totals: generator_totals,
          last_script_error: last_script_error,
          writers: writers
        } = run ->
          {counters, generator_totals} =
            Enum.reduce(push_scalars, {counters, generator_totals}, fn {key, value},
                                                                       {counters,
                                                                        generator_totals} ->
              case key do
                {subkey, :count} ->
                  {Map.update(counters, subkey, value, fn c -> c + value end), generator_totals}

                {subkey, :total} ->
                  total = %{subkey => value}

                  {counters,
                   Map.update(generator_totals, generator_id, total, fn total0 ->
                     Map.merge(total0, total)
                   end)}
              end
            end)

          last_script_error =
            if first_script_error !== last_script_error do
              :ok =
                Management.notify_all(%{
                  "last_script_error" => script_error_to_json(first_script_error)
                })

              first_script_error
            else
              last_script_error
            end

          push_hists =
            push_binary_hists
            |> Enum.map(fn {key, binary_hist} ->
              {:ok, hist} = :hdr_histogram.from_binary(binary_hist)
              {key, hist}
            end)
            |> Map.new()

          writers =
            writers
            |> Enum.map(fn {ref, %Writer{hists: hists} = writer} ->
              {ref, %{writer | hists: Histogram.add(hists, push_hists)}}
            end)
            |> Map.new()

          %{
            run
            | counters: counters,
              generator_totals: generator_totals,
              last_script_error: last_script_error,
              writers: writers
          }

        nil ->
          nil
      end

    {:noreply, %{reporter | run: run}}
  end

  def handle_cast(
        {:start_run, id, plan_name},
        %Reporter{writer_configs: writer_configs} = reporter
      ) do
    writers =
      writer_configs
      |> Enum.map(fn {module, params, interval_ms} ->
        ref = make_ref()

        send(self(), {:report, ref})

        {ref,
         %Writer{
           module: module,
           interval_ms: interval_ms,
           state: Kernel.apply(module, :init, params)
         }}
      end)
      |> Map.new()

    {:noreply,
     %{
       reporter
       | run: %Run{id: id, plan_name: plan_name, writers: writers}
     }}
  end

  def handle_cast(
        :stop_run,
        %Reporter{
          run: run,
          reports: reports
        } = reporter
      ) do
    case run do
      %Run{
        id: id,
        plan_name: plan_name,
        maximums: maximums,
        last_script_error: last_script_error,
        writers: writers
      } ->
        result_json =
          writers
          |> Enum.reduce(%{}, fn {_, %Writer{module: module, state: state, timer_ref: timer_ref}},
                                 r ->
            if timer_ref !== nil do
              Process.cancel_timer(timer_ref)
            end

            Kernel.apply(module, :finish, [r, id, state])
          end)

        reports = [
          %Report{
            id: id,
            plan_name: plan_name,
            maximums: maximums,
            script_error: last_script_error,
            result_json: result_json
          }
          | reports
        ]

        :ok =
          Management.notify_all(%{
            "last_script_error" => nil,
            "reports" => reports_to_json(reports)
          })

        {:noreply,
         %{
           reporter
           | run: nil,
             reports: reports
         }}

      nil ->
        {:noreply, reporter}
    end
  end

  def handle_cast(
        {:clear_stats, conn_id},
        %Reporter{
          run: run
        } = reporter
      ) do
    run =
      case run do
        %Run{generator_totals: generator_totals} = run ->
          %{run | generator_totals: Map.delete(generator_totals, conn_id)}

        nil ->
          nil
      end

    {:noreply,
     %{
       reporter
       | run: run
     }}
  end

  def handle_cast(
        {:remove_report, id},
        %Reporter{reports: reports} = reporter
      ) do
    reports = Enum.reject(reports, fn %Report{id: id0} -> id0 == id end)

    :ok = Management.notify_all(%{"reports" => reports_to_json(reports)})

    {:noreply,
     %{
       reporter
       | reports: reports
     }}
  end

  def handle_info(
        {:report, ref},
        %Reporter{run: run} = reporter
      ) do
    case run do
      %Run{
        id: id,
        counters: counters,
        generator_totals: generator_totals,
        maximums: maximums,
        writers: writers
      } = run ->
        case Map.get(writers, ref) do
          %Writer{
            module: module,
            interval_ms: interval_ms,
            state: state,
            clock: clock,
            hists: hists,
            prev_counters: prev_counters
          } = writer ->
            timer_ref = Process.send_after(self(), {:report, ref}, interval_ms)

            scalars =
              format_counters(counters)
              |> Map.merge(compute_rates(counters, prev_counters, interval_ms))
              |> Map.merge(compute_totals(generator_totals))

            state = Kernel.apply(module, :write, [id, clock, state, hists, scalars])

            maximums =
              maximums
              |> compute_maximums(scalars)
              |> compute_maximums(
                Enum.map(hists, fn {key, hist} -> {key, :hdr_histogram.max(hist)} end)
              )

            Enum.each(hists, fn {_, hist} ->
              :ok = :hdr_histogram.reset(hist)
            end)

            writers =
              Map.put(writers, ref, %{
                writer
                | state: state,
                  timer_ref: timer_ref,
                  clock: clock + 1,
                  prev_counters: counters
              })

            {:noreply, %{reporter | run: %{run | maximums: maximums, writers: writers}}}

          nil ->
            {:noreply, reporter}
        end

      nil ->
        {:noreply, reporter}
    end
  end

  defp reports_to_json(reports) do
    Enum.map(reports, fn %Report{
                           id: id,
                           plan_name: plan_name,
                           maximums: maximums,
                           script_error: script_error,
                           result_json: result_json
                         } ->
      json = %{
        "id" => id,
        "name" => plan_name,
        "maximums" => maximums,
        "result" => result_json
      }

      if script_error do
        Map.merge(json, %{"script_error" => script_error_to_json(script_error)})
      else
        json
      end
    end)
  end

  defp format_counters(counters) do
    counters
    |> Enum.map(fn {key, value} ->
      {:"#{key}_count", value}
    end)
    |> Map.new()
  end

  defp compute_rates(counters, prev_counters, interval_ms) do
    prev_counters
    |> Enum.map(fn {key, prev_value} ->
      value = Map.get(counters, key)

      {:"#{key}_per_second", (value - prev_value) / (interval_ms / 1_000)}
    end)
    |> Map.new()
  end

  defp compute_totals(generator_totals) do
    Enum.reduce(generator_totals, %{}, fn {_, totals}, total_sums ->
      Enum.reduce(totals, total_sums, fn {key, value}, total_sums ->
        Map.update(total_sums, key, value, fn value0 -> value0 + value end)
      end)
    end)
  end

  defp compute_maximums(maximums, scalars) do
    Enum.reduce(scalars, maximums, fn {key, value}, maximums ->
      case Map.get(maximums, key) do
        nil ->
          Map.put(maximums, key, value)

        max_value ->
          if value > max_value do
            Map.put(maximums, key, value)
          else
            maximums
          end
      end
    end)
  end

  defp script_error_to_json(%{
         script: script,
         error: %ArgumentError{message: message}
       }) do
    %{
      "script" => script,
      "description" => message
    }
  end

  defp script_error_to_json(%{
         script: script,
         error: %SyntaxError{description: description, line: line}
       }) do
    %{
      "script" => script,
      "description" => description,
      "line" => line
    }
  end

  defp script_error_to_json(%{
         script: script,
         error: %CompileError{description: description, line: line}
       }) do
    %{
      "script" => script,
      "description" => description,
      "line" => line
    }
  end

  defp script_error_to_json(%{
         script: script,
         error: %TokenMissingError{
           description: description,
           line: line
         }
       }) do
    %{
      "script" => script,
      "description" => description,
      "line" => line
    }
  end

  defp script_error_to_json(%{
         script: script,
         error: :function_clause
       }) do
    %{
      "script" => script,
      "description" => "function_clause"
    }
  end
end
