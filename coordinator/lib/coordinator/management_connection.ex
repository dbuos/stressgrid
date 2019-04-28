defmodule Stressgrid.Coordinator.ManagementConnection do
  @moduledoc false

  alias Stressgrid.Coordinator.{
    ManagementConnection,
    Scheduler,
    Reporter
  }

  @behaviour :cowboy_websocket

  require Logger

  @tick_interval 1_000

  defstruct tick_timer_ref: nil

  def init(req, _) do
    {:cowboy_websocket, req, %ManagementConnection{}, %{idle_timeout: :infinity}}
  end

  def websocket_init(%{} = connection) do
    tick_timer_ref = Process.send_after(self(), :tick, @tick_interval)

    {:ok, reports_json} = Reporter.get_reports_json()
    {:ok, grid_json} = get_grid_json()

    :ok =
      send_json(self(), [
        %{
          "init" => %{
            "reports" => reports_json,
            "grid" => grid_json
          }
        }
      ])

    Registry.register(ManagementConnection, nil, nil)
    {:ok, %{connection | tick_timer_ref: tick_timer_ref}}
  end

  def websocket_handle({:text, text}, connection) do
    connection =
      Jason.decode!(text)
      |> Enum.reduce(connection, &receive_json(&2, &1))

    {:ok, connection}
  end

  def websocket_handle({:ping, data}, connection) do
    {:reply, {:pong, data}, connection}
  end

  def websocket_info({:send, json}, connection) do
    text = Jason.encode!(json)
    {:reply, {:text, text}, connection}
  end

  def websocket_info(:tick, connection) do
    {:ok, connection |> notify_grid_changed()}
  end

  def notify(json) do
    Registry.lookup(ManagementConnection, nil)
    |> Enum.each(fn {pid, nil} ->
      send_json(pid, [%{"notify" => json}])
    end)
  end

  defp send_json(pid, json) do
    _ = Kernel.send(pid, {:send, json})
    :ok
  end

  defp receive_json(
         %ManagementConnection{} = connection,
         %{
           "run_plan" =>
             %{
               "name" => plan_name,
               "blocks" => blocks_json,
               "addresses" => addresses_json,
               "opts" => opts_json
             } = plan
         }
       )
       when is_binary(plan_name) and is_list(blocks_json) and is_list(addresses_json) do
    script = plan |> Map.get("script")
    opts = parse_opts_json(opts_json)

    blocks =
      blocks_json
      |> Enum.reduce([], fn block_json, acc ->
        case parse_block_json(block_json) do
          %{script: _} = block ->
            [block | acc]

          block ->
            if is_binary(script) do
              [block |> Map.put(:script, script) | acc]
            else
              acc
            end
        end
      end)
      |> Enum.reverse()

    addresses =
      addresses_json
      |> Enum.reduce([], fn address_json, acc ->
        case parse_address_json(address_json) do
          {_, host, _} = address when is_binary(host) ->
            [address | acc]

          _ ->
            acc
        end
      end)
      |> Enum.reverse()

    :ok = Scheduler.start_run(plan_name, blocks, addresses, opts)

    connection |> notify_grid_changed()
  end

  defp receive_json(
         %ManagementConnection{} = connection,
         "abort_run"
       ) do
    :ok = Scheduler.abort_run()

    connection |> notify_grid_changed()
  end

  defp receive_json(
         %ManagementConnection{} = connection,
         %{
           "remove_report" => %{
             "id" => id
           }
         }
       )
       when is_binary(id) do
    :ok = Reporter.remove_report(id)
    connection
  end

  defp parse_opts_json(json) do
    json
    |> Enum.reduce([], fn
      {"ramp_steps", ramp_steps}, acc when is_integer(ramp_steps) ->
        [{:ramp_steps, ramp_steps} | acc]

      {"rampup_step_ms", ms}, acc when is_integer(ms) ->
        [{:rampup_step_ms, ms} | acc]

      {"sustain_ms", ms}, acc when is_integer(ms) ->
        [{:sustain_ms, ms} | acc]

      {"rampdown_step_ms", ms}, acc when is_integer(ms) ->
        [{:rampdown_step_ms, ms} | acc]

      _, acc ->
        acc
    end)
  end

  defp parse_block_json(json) do
    json
    |> Enum.reduce([], fn
      {"script", script}, acc when is_binary(script) ->
        [{:script, script} | acc]

      {"params", params}, acc when is_map(params) ->
        [{:params, params} | acc]

      {"size", size}, acc when is_integer(size) ->
        [{:size, size} | acc]

      _, acc ->
        acc
    end)
    |> Map.new()
  end

  defp parse_address_json(json) do
    json
    |> Enum.reduce({:http, nil, 80}, fn
      {"host", host}, acc when is_binary(host) ->
        acc |> put_elem(1, host)

      {"port", port}, acc when is_integer(port) ->
        acc |> put_elem(2, port)

      {"protocol", "http"}, acc ->
        acc |> put_elem(0, :http)

      {"protocol", "https"}, acc ->
        acc |> put_elem(0, :https)

      {"protocol", "http2"}, acc ->
        acc |> put_elem(0, :http2)

      {"protocol", "http2s"}, acc ->
        acc |> put_elem(0, :http2s)

      {"protocol", "udp"}, acc ->
        acc |> put_elem(0, :udp)

      _, acc ->
        acc
    end)
  end

  defp notify_grid_changed(%ManagementConnection{tick_timer_ref: tick_timer_ref} = connection) do
    Process.cancel_timer(tick_timer_ref)
    tick_timer_ref = Process.send_after(self(), :tick, @tick_interval)

    {:ok, grid_json} = get_grid_json()

    :ok =
      notify(%{
        "grid_changed" => grid_json
      })

    %{connection | tick_timer_ref: tick_timer_ref}
  end

  defp get_grid_json do
    {:ok, telemetry_json} = Reporter.get_telemetry_json()

    run_json =
      case Scheduler.get_run_json() do
        {:ok, run_json} ->
          run_json

        :no_run ->
          nil
      end

    {:ok,
     %{
       "telemetry" => telemetry_json,
       "run" => run_json
     }}
  end
end
