defmodule Stressgrid.Generator.Connection do
  @moduledoc false

  use GenServer
  require Logger

  alias Stressgrid.Generator.{Connection, Cohort, Device, Histogram}

  @conn_timeout 5_000
  @report_interval 1_000
  @snmp_known_counters %{
    "Tcp.RetransSegs" => :tcp_retr_seg_error,
    "Tcp.InErrs" => :tcp_bad_seg_error
  }

  defstruct id: nil,
            conn_pid: nil,
            wall_times: nil,
            timeout_ref: nil,
            stream_ref: nil,
            cohorts: %{},
            address_base: 0,
            base_network_stats: nil,
            network_device_name: nil

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(args) do
    :erlang.system_flag(:scheduler_wall_time, true)

    network_device_name =
      read_network_device_names()
      |> find_network_device_name(System.get_env() |> Map.get("NETWORK_DEVICE"))

    Logger.info("Collecting network stats from #{inspect(network_device_name)}")

    host = args |> Keyword.fetch!(:host)
    port = args |> Keyword.fetch!(:port)

    {:ok, conn_pid} =
      :gun.open(
        host |> String.to_charlist(),
        port,
        %{
          retry: 0
        }
      )

    timeout_ref = Process.send_after(self(), :timeout, @conn_timeout)

    Logger.info("Connecting to coordinator at #{host}:#{port}...")

    {:ok,
     %Connection{
       id: args |> Keyword.fetch!(:id),
       conn_pid: conn_pid,
       timeout_ref: timeout_ref,
       network_device_name: network_device_name
     }}
  end

  def handle_info(
        :timeout,
        %Connection{conn_pid: conn_pid} = connection
      ) do
    Logger.warn("Connection timeout")

    :ok = :gun.close(conn_pid)

    {:stop, :shutdown, connection}
  end

  def handle_info(
        {:gun_up, conn_pid, _protocol},
        %Connection{conn_pid: conn_pid} = connection
      ) do
    stream_ref = :gun.ws_upgrade(conn_pid, "/")
    {:noreply, %{connection | stream_ref: stream_ref}}
  end

  def handle_info(
        {:gun_down, conn_pid, :ws, reason, _, _},
        %Connection{conn_pid: conn_pid} = connection
      ) do
    {:stop, {:disconnected, reason}, terminate_cohorts(connection)}
  end

  def handle_info(
        {:gun_error, conn_pid, _, reason},
        %Connection{conn_pid: conn_pid} = connection
      ) do
    {:stop, {:error, reason}, terminate_cohorts(connection)}
  end

  def handle_info(
        {:gun_upgrade, conn_pid, stream_ref, ["websocket"], _headers},
        %Connection{id: id, conn_pid: conn_pid, stream_ref: stream_ref, timeout_ref: timeout_ref} =
          connection
      ) do
    connection =
      connection
      |> register(id)

    Logger.info("Connected")

    Process.cancel_timer(timeout_ref)
    Process.send_after(self(), :report, @report_interval)

    {:noreply, %{connection | timeout_ref: nil}}
  end

  def handle_info(
        {:gun_response, conn_pid, _, _, status, _headers},
        %Connection{conn_pid: conn_pid} = connection
      ) do
    Logger.error("Connection error upgrading to ws: #{status}")
    {:stop, :shutdown, connection}
  end

  def handle_info(
        {:gun_error, conn_pid, stream_ref, reason},
        %Connection{conn_pid: conn_pid, stream_ref: stream_ref} = connection
      ) do
    Logger.error("Connection error: #{inspect(reason)}")
    {:stop, :shutdown, connection}
  end

  def handle_info(
        {:gun_ws, conn_pid, stream_ref, {:binary, frame}},
        %Connection{conn_pid: conn_pid, stream_ref: stream_ref} = connection
      ) do
    connection =
      :erlang.binary_to_term(frame)
      |> Enum.reduce(connection, &receive_term(&2, &1))

    {:noreply, connection}
  end

  def handle_info(
        {:gun_ws, conn_pid, stream_ref, _},
        %Connection{conn_pid: conn_pid, stream_ref: stream_ref} = connection
      ) do
    {:noreply, connection}
  end

  def handle_info(:report, %Connection{} = connection) do
    Process.send_after(self(), :report, @report_interval)

    {first_script_error, active_device_number, aggregate_hists, aggregate_scalars} =
      Supervisor.which_children(Cohort.Supervisor)
      |> Enum.reduce({nil, 0, %{}, %{}}, fn {_, cohort_pid, _, _}, a ->
        Supervisor.which_children(cohort_pid)
        |> Enum.reduce(a, fn {_, device_pid, _, _},
                             {first_script_error, active_device_number, aggregate_hists,
                              aggregate_scalars} ->
          {:ok, script_error, is_active, aggregate_hists, device_scalars} =
            Device.collect(device_pid, aggregate_hists)

          aggregate_scalars =
            Enum.reduce(device_scalars, aggregate_scalars, fn {key, value}, scalars ->
              Map.update(scalars, key, value, fn c -> c + value end)
            end)

          {if(first_script_error !== nil, do: first_script_error, else: script_error),
           active_device_number + if(is_active, do: 1, else: 0), aggregate_hists,
           aggregate_scalars}
        end)
      end)

    {connection, network_stats_scalars} =
      network_stats_scalars(connection, active_device_number != 0)

    {:ok, cpu_percent, connection} = cpu_utilization_percent(connection)
    telemetry_hists = Histogram.record(aggregate_hists, :cpu_percent, cpu_percent)

    telemetry_scalars =
      Map.merge(
        aggregate_scalars,
        Map.merge(
          %{
            {:active_device_number, :total} => active_device_number
          },
          network_stats_scalars
        )
      )

    telemetry = %{
      first_script_error: first_script_error,
      scalars: telemetry_scalars,
      hists:
        telemetry_hists
        |> Enum.map(fn {key, hist} ->
          {key, :hdr_histogram.to_binary(hist)}
        end)
        |> Map.new()
    }

    connection =
      connection
      |> push_telemetry(telemetry)

    {:noreply, connection}
  end

  defp receive_term(
         %Connection{cohorts: cohorts, address_base: address_base} = connection,
         {:start_cohort, %{id: id, blocks: blocks, addresses: addresses}}
       )
       when is_binary(id) and is_list(blocks) do
    {:ok, cohort_pid} = Cohort.Supervisor.start_child(id)

    i =
      blocks
      |> Enum.reduce(0, fn %{script: script} = block, i when is_binary(script) ->
        params = block |> Map.get(:params, %{})
        size = block |> Map.get(:size, 1)

        if size > 0 and addresses != [] do
          1..size
          |> Enum.reduce(i, fn _, i ->
            address =
              addresses
              |> Enum.at(rem(address_base + i, length(addresses)))

            {:ok, _} =
              Device.Supervisor.start_child(
                cohort_pid,
                "#{id}-#{i}",
                address,
                script,
                params
              )

            i + 1
          end)
        else
          i
        end
      end)

    %{connection | cohorts: cohorts |> Map.put(id, cohort_pid), address_base: address_base + i}
  end

  defp receive_term(
         %Connection{cohorts: cohorts} = connection,
         {:stop_cohort, %{id: id}}
       )
       when is_binary(id) do
    case cohorts |> Map.get(id) do
      nil ->
        connection

      pid ->
        :ok = Cohort.Supervisor.terminate_child(pid)
        %{connection | cohorts: cohorts |> Map.delete(id)}
    end
  end

  defp send_terms(%Connection{conn_pid: conn_pid} = connection, terms) when is_list(terms) do
    :ok = :gun.ws_send(conn_pid, {:binary, :erlang.term_to_binary(terms)})
    connection
  end

  defp register(connection, id) do
    connection
    |> send_terms([{:register, %{id: id}}])
  end

  defp push_telemetry(connection, telemetry) do
    connection
    |> send_terms([{:push_telemetry, telemetry}])
  end

  defp terminate_cohorts(%Connection{cohorts: cohorts} = connection) do
    :ok =
      cohorts
      |> Enum.each(fn {_, pid} ->
        :ok = Cohort.Supervisor.terminate_child(pid)
      end)

    %{connection | cohorts: %{}}
  end

  defp network_stats_scalars(
         %Connection{
           network_device_name: network_device_name,
           base_network_stats: base_network_stats
         } = connection,
         is_active
       ) do
    if is_active do
      network_device_stats =
        case read_network_device_stats(network_device_name) do
          {:ok, stats} ->
            stats

          _ ->
            %{}
        end

      network_snmp_stats =
        case read_network_snmp_stats() do
          {:ok, stats} ->
            stats

          _ ->
            %{}
        end

      network_stats = Map.merge(network_device_stats, network_snmp_stats)

      if base_network_stats != nil do
        {connection,
         network_stats
         |> Enum.reduce(%{}, fn
           {_, 0}, a ->
             a

           {key, value}, a ->
             case Map.get(base_network_stats, key) do
               nil ->
                 a

               ^value ->
                 a

               base_value ->
                 Map.put(a, key, value - base_value)
             end
         end)
         |> Enum.map(fn {key, value} -> {{:"network_#{key}", :count}, value} end)
         |> Map.new()}
      else
        {%{connection | base_network_stats: network_stats}, %{}}
      end
    else
      if base_network_stats != nil do
        {%{connection | base_network_stats: nil}, %{}}
      else
        {connection, %{}}
      end
    end
  end

  defp read_network_device_names do
    case File.read("/proc/net/dev") do
      {:ok, r} ->
        case r |> String.split("\n", trim: true) do
          [_ | [_ | devs]] ->
            devs
            |> Enum.reduce([], fn dev, acc ->
              case dev |> String.split(" ", trim: true) do
                [header | _] ->
                  [header |> String.trim_trailing(":") | acc]

                _ ->
                  acc
              end
            end)

          _ ->
            []
        end

      error ->
        Logger.error("Error reading /proc/net/dev: #{inspect(error)}")
        []
    end
  end

  defp find_network_device_name(device_names, device_name) do
    case device_names
         |> Enum.find(fn
           ^device_name -> true
           _ -> false
         end) do
      nil ->
        case device_names
             |> Enum.reject(fn
               "lo" -> true
               _ -> false
             end) do
          [device_name | _] ->
            device_name

          _ ->
            nil
        end

      device_name ->
        device_name
    end
  end

  defp read_network_snmp_stats do
    case File.read("/proc/net/snmp") do
      {:ok, r} ->
        stats =
          r
          |> String.split("\n", trim: true)
          |> Enum.chunk_every(2)
          |> Enum.reduce(%{}, fn
            [line0, line1], a ->
              case {String.split(line0, ":", trim: true), String.split(line1, ":", trim: true)} do
                {[group, headers], [group, values]} ->
                  headers_and_values =
                    Enum.zip(
                      String.split(headers, " ", trim: true),
                      String.split(values, " ", trim: true)
                    )

                  Enum.reduce(headers_and_values, a, fn {header, value}, a ->
                    Map.put(
                      a,
                      "#{group}.#{header}",
                      String.to_integer(value)
                    )
                  end)

                _ ->
                  a
              end

            _, a ->
              a
          end)
          |> Enum.reduce(%{}, fn {snmp_key, value}, a ->
            case Map.get(@snmp_known_counters, snmp_key) do
              nil ->
                a

              known_key ->
                Map.put(a, known_key, value)
            end
          end)

        {:ok, stats}

      error ->
        Logger.error("Error reading /proc/net/snmp: #{inspect(error)}")
        error
    end
  end

  defp read_network_device_stats(device_name) do
    case File.read("/proc/net/dev") do
      {:ok, r} ->
        case String.split(r, "\n", trim: true) do
          [_ | [_ | devs]] ->
            Enum.reduce(devs, :error, fn
              dev, :error ->
                case String.split(dev, " ", trim: true) do
                  [header | info] ->
                    case String.trim_trailing(header, ":") do
                      ^device_name ->
                        [
                          rx_bytes,
                          rx_packets,
                          rx_error,
                          rx_dropped_error,
                          rx_fifo_error,
                          rx_frame_error,
                          _,
                          _,
                          tx_bytes,
                          tx_packets,
                          tx_error,
                          tx_dropped_error,
                          tx_fifo_error,
                          tx_collision_error,
                          tx_carrier_error,
                          _
                        ] = info

                        {:ok,
                         %{
                           dev_rx_bytes: String.to_integer(rx_bytes),
                           dev_rx_packets: String.to_integer(rx_packets),
                           dev_rx_error: String.to_integer(rx_error),
                           dev_rx_dropped_error: String.to_integer(rx_dropped_error),
                           dev_rx_fifo_error: String.to_integer(rx_fifo_error),
                           dev_rx_frame_error: String.to_integer(rx_frame_error),
                           dev_tx_bytes: String.to_integer(tx_bytes),
                           dev_tx_packets: String.to_integer(tx_packets),
                           dev_tx_error: String.to_integer(tx_error),
                           dev_tx_dropped_error: String.to_integer(tx_dropped_error),
                           dev_tx_fifo_error: String.to_integer(tx_fifo_error),
                           dev_tx_collision_error: String.to_integer(tx_collision_error),
                           dev_tx_carrier_error: String.to_integer(tx_carrier_error)
                         }}

                      _ ->
                        :error
                    end

                  _ ->
                    :error
                end

              _, r ->
                r
            end)

          _ ->
            :error
        end

      error ->
        Logger.error("Error reading /proc/net/dev: #{inspect(error)}")
        error
    end
  end

  defp cpu_utilization_percent(%Connection{wall_times: prev_wall_times} = connection) do
    next_wall_times =
      :erlang.statistics(:scheduler_wall_time)
      |> Enum.sort()
      |> Enum.take(:erlang.system_info(:schedulers))

    utilization =
      if prev_wall_times != nil do
        {da, dt} =
          Enum.zip(prev_wall_times, next_wall_times)
          |> Enum.reduce({0, 0}, fn {{_, a0, t0}, {_, a1, t1}}, {da, dt} ->
            {da + (a1 - a0), dt + (t1 - t0)}
          end)

        da / dt
      else
        0
      end

    utilization_percent = round(utilization * 100)

    {:ok, utilization_percent, %{connection | wall_times: next_wall_times}}
  end
end
