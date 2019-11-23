defmodule Stressgrid.Coordinator.ManagementConnection do
  @moduledoc false

  alias Stressgrid.Coordinator.{
    ManagementConnection,
    Scheduler,
    Reporter,
    Management
  }

  @behaviour :cowboy_websocket

  require Logger

  defstruct []

  def init(req, _) do
    {:cowboy_websocket, req, %ManagementConnection{}, %{idle_timeout: :infinity}}
  end

  def websocket_init(%ManagementConnection{} = connection) do
    Management.connect()
    {:ok, connection}
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

  def websocket_info(
        {:send, envelope, json},
        %ManagementConnection{} = connection
      ) do
    text = Jason.encode!([%{envelope => json}])
    {:reply, {:text, text}, connection}
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
          {protocol, host, port} when is_binary(host) ->
            case :inet.gethostbyname(host |> String.to_charlist()) do
              {:ok, {:hostent, _, _, _, _, ips}} ->
                ips
                |> Enum.map(fn ip -> {protocol, ip, port, host} end)
                |> Enum.concat(acc)

              _ ->
                acc
            end

          _ ->
            acc
        end
      end)
      |> Enum.uniq()

    :ok = Scheduler.start_run(plan_name, blocks, addresses, opts)

    connection
  end

  defp receive_json(
         %ManagementConnection{} = connection,
         "abort_run"
       ) do
    :ok = Scheduler.abort_run()

    connection
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

      {"protocol", "http10"}, acc ->
        acc |> put_elem(0, :http10)

      {"protocol", "http10s"}, acc ->
        acc |> put_elem(0, :http10s)

      {"protocol", "http"}, acc ->
        acc |> put_elem(0, :http)

      {"protocol", "https"}, acc ->
        acc |> put_elem(0, :https)

      {"protocol", "http2"}, acc ->
        acc |> put_elem(0, :http2)

      {"protocol", "http2s"}, acc ->
        acc |> put_elem(0, :http2s)

      {"protocol", "tcp"}, acc ->
        acc |> put_elem(0, :tcp)

      {"protocol", "udp"}, acc ->
        acc |> put_elem(0, :udp)

      _, acc ->
        acc
    end)
  end
end
