defmodule Stressgrid.Generator.GunDevice do
  @moduledoc false

  alias Stressgrid.Generator.{
    Device,
    GunDevice,
    GunDeviceContext
  }

  use GenServer

  use Device,
    device_macros: [
      {GunDeviceContext,
       [
         get: 1,
         get: 2,
         options: 1,
         options: 2,
         delete: 1,
         delete: 2,
         post: 1,
         post: 2,
         post: 3,
         put: 1,
         put: 2,
         put: 3,
         patch: 1,
         patch: 2,
         patch: 3
       ]
       |> Enum.sort()}
    ]

  require Logger

  defstruct address: nil,
            conn_pid: nil,
            conn_ref: nil,
            request_from: nil,
            stream_ref: nil,
            response_status: nil,
            response_headers: nil,
            response_iodata: nil

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    {:ok, %GunDevice{address: args |> Keyword.fetch!(:address)} |> Device.init(args)}
  end

  def request(pid, method, path, headers, body) when is_map(headers) do
    request(pid, method, path, headers |> Map.to_list(), body)
  end

  def request(pid, method, path, headers, body) when is_list(headers) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:request, method, path, headers, body})
    else
      exit(:device_terminated)
    end
  end

  def handle_call({:request, _, _, _, _}, _, %GunDevice{conn_pid: nil} = device) do
    {:reply, {:error, :disconnected}, device}
  end

  def handle_call(
        {:request, method, path, headers, body},
        request_from,
        %GunDevice{conn_pid: conn_pid, stream_ref: nil, request_from: nil} = device
      ) do
    Logger.debug("Starting request #{method} #{path}")

    case prepare_request(headers, body) do
      {:ok, headers, body} ->
        device =
          device
          |> Device.do_start_timing(:headers)

        stream_ref = :gun.request(conn_pid, method, path, headers, body)

        device = %{device | stream_ref: stream_ref, request_from: request_from}
        {:noreply, device}

      error ->
        {:reply, error, device}
    end
  end

  def handle_info(
        :open,
        %GunDevice{conn_pid: nil, address: {protocol, host, port}} = device
      )
      when protocol in [:http, :https, :http2, :http2s] do
    Logger.debug("Open gun #{host}:#{port}")

    device =
      device
      |> Device.do_start_timing(:conn)

    {:ok, conn_pid} =
      :gun.start_link(self(), host |> String.to_charlist(), port, %{
        retry: 0,
        transport: transport(protocol),
        protocols: protocols(protocol),
        http_opts: %{keepalive: :infinity}
      })

    conn_ref = Process.monitor(conn_pid)
    true = Process.unlink(conn_pid)

    {:noreply, %{device | conn_pid: conn_pid, conn_ref: conn_ref}}
  end

  def handle_info(
        :recycled,
        %GunDevice{conn_pid: conn_pid, conn_ref: conn_ref, stream_ref: stream_ref} = device
      ) do
    if conn_ref != nil do
      true = Process.demonitor(conn_ref, [:flush])

      if stream_ref == nil do
        :ok =
          try do
            case :gun.info(conn_pid) do
              %{socket: socket, transport: :tcp} ->
                :gun_tcp.setopts(socket, [{:linger, {true, 0}}])
                :gun_tcp.close(socket)
                :ok

              %{transport: :tls} ->
                :ok
            end
          catch
            :exit, {:noproc, {:sys, :get_state, _}} ->
              :ok
          end
      end

      _ = :gun.shutdown(conn_pid)
    end

    {:noreply,
     %{
       device
       | conn_pid: nil,
         conn_ref: nil,
         request_from: nil,
         stream_ref: nil,
         response_status: nil,
         response_headers: nil,
         response_iodata: nil
     }}
  end

  def handle_info(
        {:gun_up, conn_pid, _protocol},
        %GunDevice{
          conn_pid: conn_pid
        } = device
      ) do
    Logger.debug("Gun up")

    {:noreply,
     device
     |> Device.start_task()
     |> Device.inc_counter("conn_count" |> String.to_atom(), 1)
     |> Device.do_stop_timing(:conn)}
  end

  def handle_info(
        {:gun_down, conn_pid, _, reason, _, _},
        %GunDevice{
          conn_pid: conn_pid
        } = device
      ) do
    Logger.debug("Gun down with #{inspect(reason)}")

    {:noreply,
     device
     |> Device.recycle(true)
     |> Device.inc_counter(reason |> gun_reason_to_key(), 1)}
  end

  def handle_info(
        {:gun_response, conn_pid, stream_ref, is_fin, status, headers},
        %GunDevice{
          conn_pid: conn_pid,
          stream_ref: stream_ref
        } = device
      ) do
    device = %{device | response_status: status, response_headers: headers, response_iodata: []}

    device =
      case is_fin do
        :nofin ->
          device
          |> Device.do_stop_start_timing(:headers, :body)

        :fin ->
          device
          |> complete_request()
          |> Device.do_stop_timing(:headers)
      end

    device =
      device
      |> Device.inc_counter("response_count" |> String.to_atom(), 1)

    {:noreply, device}
  end

  def handle_info(
        {:gun_data, conn_pid, stream_ref, is_fin, data},
        %GunDevice{
          conn_pid: conn_pid,
          stream_ref: stream_ref,
          response_iodata: response_iodata
        } = device
      ) do
    device = %{device | response_iodata: [data | response_iodata]}

    device =
      case is_fin do
        :nofin ->
          device

        :fin ->
          device
          |> complete_request()
          |> Device.do_stop_timing(:body)
      end

    {:noreply, device}
  end

  def handle_info(
        {:gun_error, conn_pid, stream_ref, reason},
        %GunDevice{
          stream_ref: stream_ref,
          conn_pid: conn_pid
        } = device
      ) do
    Logger.debug("Gun error #{inspect(reason)}")

    {:noreply,
     device
     |> Device.recycle(true)
     |> Device.inc_counter(reason |> gun_reason_to_key(), 1)}
  end

  def handle_info(
        {:gun_error, conn_pid, reason},
        %GunDevice{
          conn_pid: conn_pid
        } = device
      ) do
    Logger.debug("Gun error #{inspect(reason)}")

    {:noreply,
     device
     |> Device.recycle(true)
     |> Device.inc_counter(reason |> gun_reason_to_key(), 1)}
  end

  def handle_info(
        {:DOWN, conn_ref, :process, conn_pid, reason},
        %GunDevice{
          conn_ref: conn_ref,
          conn_pid: conn_pid
        } = device
      ) do
    Logger.debug("Gun exited with #{inspect(reason)}")

    {:noreply,
     device
     |> Device.recycle(true)
     |> Device.inc_counter(reason |> gun_reason_to_key(), 1)}
  end

  def handle_info(
        _,
        device
      ) do
    {:noreply, device}
  end

  defp complete_request(
         %GunDevice{
           request_from: request_from,
           response_status: response_status,
           response_headers: response_headers,
           response_iodata: response_iodata
         } = device
       ) do
    Logger.debug("Complete request #{response_status}")

    if request_from != nil do
      response_iodata = response_iodata |> Enum.reverse()

      response_body =
        case response_headers |> List.keyfind("content-type", 0) do
          {_, content_type} ->
            case :cow_http_hd.parse_content_type(content_type) do
              {"application", "json", _} ->
                case Jason.decode(response_iodata) do
                  {:ok, json} ->
                    {:json, json}

                  _ ->
                    response_iodata
                end

              _ ->
                response_iodata
            end

          _ ->
            response_iodata
        end

      GenServer.reply(
        request_from,
        {response_status, response_headers, response_body}
      )
    end

    %{
      device
      | request_from: nil,
        stream_ref: nil,
        response_status: nil,
        response_headers: nil,
        response_iodata: nil
    }
  end

  defp gun_reason_to_key(:normal) do
    :closed_error_count
  end

  defp gun_reason_to_key(:closed) do
    :conn_lost_error_count
  end

  defp gun_reason_to_key({:shutdown, :econnrefused}) do
    :conn_refused_error_count
  end

  defp gun_reason_to_key({:shutdown, :econnreset}) do
    :conn_reset_error_count
  end

  defp gun_reason_to_key({:shutdown, :nxdomain}) do
    :nx_domain_error_count
  end

  defp gun_reason_to_key({:shutdown, :etimedout}) do
    :conn_timedout_error_count
  end

  defp gun_reason_to_key({:shutdown, :eaddrnotavail}) do
    :addr_not_avail_error_count
  end

  defp gun_reason_to_key({:shutdown, :ehostdown}) do
    :host_down_error_count
  end

  defp gun_reason_to_key({:shutdown, :ehostunreach}) do
    :host_unreach_error_count
  end

  defp gun_reason_to_key({:shutdown, :emfile}) do
    :too_many_open_files_error_count
  end

  defp gun_reason_to_key({:shutdown, :closed}) do
    :conn_lost_error_count
  end

  defp gun_reason_to_key({:shutdown, {:tls_alert, _}}) do
    :tls_alert_error_count
  end

  defp gun_reason_to_key({:stream_error, _, _}) do
    :http2_stream_error_count
  end

  defp gun_reason_to_key({:closed, _}) do
    :conn_lost_error_count
  end

  defp gun_reason_to_key({:badstate, _}) do
    :bad_conn_state_error_count
  end

  defp gun_reason_to_key(:noproc) do
    :conn_terminated_error_count
  end

  defp gun_reason_to_key(reason) do
    Logger.error("Gun error #{inspect(reason)}")

    :unknown_error_count
  end

  def prepare_request(headers, body) when is_binary(body) do
    {:ok, headers, body}
  end

  def prepare_request(headers, {:json, json}) do
    case Jason.encode(json) do
      {:ok, body} ->
        headers =
          headers
          |> Enum.reject(fn
            {"content-type", _} -> true
            {"Content-Type", _} -> true
            _ -> false
          end)
          |> Enum.concat([{"content-type", "application/json; charset=utf-8"}])

        {:ok, headers, body}

      error ->
        error
    end
  end

  defp transport(:http), do: :tcp
  defp transport(:https), do: :tls

  defp transport(:http2), do: :tcp
  defp transport(:http2s), do: :tls

  defp protocols(:http), do: [:http]
  defp protocols(:https), do: [:http]

  defp protocols(:http2), do: [:http2]
  defp protocols(:http2s), do: [:http2]
end
