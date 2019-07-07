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
         patch: 3,
         ws_upgrade: 1,
         ws_upgrade: 2,
         ws_send: 1,
         ws_send_text: 1,
         ws_send_binary: 1,
         ws_receive: 0,
         ws_receive: 1
       ]
       |> Enum.sort()}
    ]

  require Logger

  @max_received_ws_frames 1024

  defstruct address: nil,
            conn_pid: nil,
            conn_ref: nil,
            request_from: nil,
            stream_ref: nil,
            response_status: nil,
            response_headers: nil,
            response_iodata: nil,
            ws_upgraded: false,
            waiting_ws_receive_froms: [],
            received_ws_frames: []

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

  def ws_upgrade(pid, path, headers) when is_map(headers) do
    ws_upgrade(pid, path, headers |> Map.to_list())
  end

  def ws_upgrade(pid, path, headers) when is_list(headers) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:ws_upgrade, path, headers})
    else
      exit(:device_terminated)
    end
  end

  def ws_send(pid, frames) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:ws_send, frames})
    else
      exit(:device_terminated)
    end
  end

  def ws_receive(pid, timeout) do
    if Process.alive?(pid) do
      GenServer.call(pid, :ws_receive, timeout)
    else
      exit(:device_terminated)
    end
  end

  def handle_call(call, from, %GunDevice{conn_pid: nil} = device) do
    device =
      device
      |> connect()

    handle_call(call, from, device)
  end

  def handle_call({:request, _, _, _, _}, _, %GunDevice{ws_upgraded: true} = device) do
    {:reply, {:error, :ws_upgraded}, device}
  end

  def handle_call(
        {:request, method, path, headers, body},
        request_from,
        %GunDevice{
          address: {_, _, _, host},
          conn_pid: conn_pid,
          stream_ref: nil,
          request_from: nil
        } = device
      ) do
    Logger.debug("Starting request #{method} #{path}")

    case prepare_request(headers, body) do
      {:ok, headers, body} ->
        device =
          device
          |> Device.do_start_timing(:headers)

        headers =
          headers
          |> add_host_to_headers(host)

        stream_ref = :gun.request(conn_pid, method, path, headers, body)

        device = %{device | stream_ref: stream_ref, request_from: request_from}
        {:noreply, device}

      error ->
        {:reply, error, device}
    end
  end

  def handle_call({:ws_upgrade, _, _}, _, %GunDevice{ws_upgraded: true} = device) do
    {:reply, {:error, :already_ws_upgraded}, device}
  end

  def handle_call(
        {:ws_upgrade, path, headers},
        request_from,
        %GunDevice{
          address: {_, _, _, host},
          conn_pid: conn_pid,
          stream_ref: nil,
          request_from: nil
        } = device
      ) do
    Logger.debug("Starting websocket upgrade #{path}")

    device =
      device
      |> Device.do_start_timing(:ws_upgrade)

    headers =
      headers
      |> add_host_to_headers(host)

    stream_ref = :gun.ws_upgrade(conn_pid, path, headers)

    device = %{device | stream_ref: stream_ref, request_from: request_from}
    {:noreply, device}
  end

  def handle_call(
        {:ws_send, _},
        _,
        %GunDevice{stream_ref: nil} = device
      ) do
    Logger.warn("Must be upgraded to send websocket frame")

    {:reply, {:error, :must_ws_upgrade}, device}
  end

  def handle_call(
        {:ws_send, frame},
        _,
        %GunDevice{
          conn_pid: conn_pid
        } = device
      ) do
    Logger.debug("Sending websocket frame")

    :ok = :gun.ws_send(conn_pid, frame)

    {:reply, :ok, device}
  end

  def handle_call(
        :ws_receive,
        _,
        %GunDevice{received_ws_frames: [frame | received_ws_frames]} = device
      ) do
    {:reply, {:ok, frame}, %{device | received_ws_frames: received_ws_frames}}
  end

  def handle_call(
        :ws_receive,
        ws_receive_from,
        %GunDevice{waiting_ws_receive_froms: waiting_ws_receive_froms} = device
      ) do
    {:noreply,
     %{device | waiting_ws_receive_froms: waiting_ws_receive_froms ++ [ws_receive_from]}}
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
     |> Device.inc_counter("conn_count" |> String.to_atom(), 1)
     |> Device.do_stop_timing(:conn)}
  end

  def handle_info(
        {:gun_down, conn_pid, _, :closed, _, _},
        %GunDevice{
          conn_pid: conn_pid,
          conn_ref: conn_ref,
          stream_ref: nil
        } = device
      ) do
    Logger.debug("Gun down with closed")

    true = Process.demonitor(conn_ref, [:flush])

    device = %{device | conn_pid: nil, conn_ref: nil}

    {:noreply, device}
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
     |> Device.recycle()
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
     |> Device.recycle()
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
     |> Device.recycle()
     |> Device.inc_counter(reason |> gun_reason_to_key(), 1)}
  end

  def handle_info(
        {:gun_upgrade, conn_pid, stream_ref, ["websocket"], response_headers},
        %GunDevice{stream_ref: stream_ref, conn_pid: conn_pid, request_from: request_from} =
          device
      ) do
    Logger.debug("Websocket upgrade succeeded")

    device =
      %{
        device
        | request_from: nil,
          ws_upgraded: true
      }
      |> Device.do_stop_timing(:ws_upgrade)

    GenServer.reply(
      request_from,
      {:ok, response_headers}
    )

    {:noreply, device}
  end

  def handle_info(
        {:gun_ws, conn_pid, stream_ref, frame},
        %GunDevice{
          stream_ref: stream_ref,
          conn_pid: conn_pid,
          waiting_ws_receive_froms: [],
          received_ws_frames: received_ws_frames
        } = device
      ) do
    if length(received_ws_frames) > @max_received_ws_frames do
      Logger.debug("Discarded websocket frame")

      {:noreply, device}
    else
      Logger.debug("Received websocket frame")

      {:noreply, %{device | received_ws_frames: received_ws_frames ++ [frame]}}
    end
  end

  def handle_info(
        {:gun_ws, conn_pid, stream_ref, frame},
        %GunDevice{
          stream_ref: stream_ref,
          conn_pid: conn_pid,
          waiting_ws_receive_froms: [ws_receive_from | waiting_ws_receive_froms]
        } = device
      ) do
    Logger.debug("Received websocket frame for waiting receive")
    GenServer.reply(ws_receive_from, {:ok, frame})
    {:noreply, %{device | waiting_ws_receive_froms: waiting_ws_receive_froms}}
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
     |> Device.recycle()
     |> Device.inc_counter(reason |> gun_reason_to_key(), 1)}
  end

  def handle_info(
        message,
        device
      ) do
    Logger.debug("Unexpected message #{inspect(message)}")

    {:noreply, device}
  end

  def open(device) do
    device
    |> Device.start_task()
  end

  def close(%GunDevice{conn_pid: conn_pid, conn_ref: conn_ref, stream_ref: stream_ref} = device) do
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

    %{
      device
      | conn_pid: nil,
        conn_ref: nil,
        request_from: nil,
        stream_ref: nil,
        response_status: nil,
        response_headers: nil,
        response_iodata: nil,
        ws_upgraded: false
    }
  end

  defp connect(%GunDevice{conn_pid: nil, address: {protocol, ip, port, host}} = device)
       when protocol in [:http10, :http10s, :http, :https, :http2, :http2s] do
    Logger.debug("Connect gun #{:inet.ntoa(ip)}:#{port}")

    protocols = protocols(protocol)
    transport = transport(protocol)

    transport_opts =
      case transport do
        :tls ->
          alpn_advertised_protocols =
            case protocol do
              :http10s -> ["http/1.0"]
              :https -> ["http/1.1"]
              :http2s -> ["h2"]
            end

          [
            verify: :verify_none,
            alpn_advertised_protocols: alpn_advertised_protocols,
            server_name_indication: host |> String.to_charlist()
          ]

        _ ->
          []
      end

    opts =
      %{
        retry: 0,
        protocols: protocols,
        transport: transport,
        transport_opts: transport_opts
      }
      |> Map.merge(protocol_opts(protocol))

    device =
      device
      |> Device.do_start_timing(:conn)

    {:ok, conn_pid} = :gun.start_link(self(), ip, port, opts)

    conn_ref = Process.monitor(conn_pid)
    true = Process.unlink(conn_pid)

    %{device | conn_pid: conn_pid, conn_ref: conn_ref}
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

  def add_host_to_headers(headers, host) do
    headers
    |> Enum.reject(fn
      {"host", _} -> true
      {"Host", _} -> true
      _ -> false
    end)
    |> Enum.concat([{"host", host}])
  end

  defp transport(protocol) when protocol in [:http10, :http, :http2], do: :tcp
  defp transport(protocol) when protocol in [:http10s, :https, :http2s], do: :tls

  defp protocols(protocol) when protocol in [:http10, :http10s, :http, :https], do: [:http]
  defp protocols(protocol) when protocol in [:http2, :http2s], do: [:http2]

  defp protocol_opts(protocol) when protocol in [:http10, :http10s] do
    %{http_opts: %{version: :"HTTP/1.0", keepalive: :infinity}}
  end

  defp protocol_opts(protocol) when protocol in [:http, :https] do
    %{http_opts: %{keepalive: :infinity}}
  end

  defp protocol_opts(protocol) when protocol in [:http2, :http2s] do
    %{http2_opts: %{keepalive: :infinity}}
  end
end
