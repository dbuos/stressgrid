defmodule Stressgrid.Generator.ChildGunDevice do
  @moduledoc false

  alias Stressgrid.Generator.{
    Device,
    GunDevice
  }

  use GenServer

  require Logger

  def start_link(%GunDevice{} = arg) do
    GenServer.start_link(__MODULE__, arg)
  end

  def init(arg) do
    {:ok, connect(arg)}
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

  def await_connection(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :await_connection, 10000)
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

  def handle_call(:await_connection, from, device) do
    case Process.get(:is_gun_up, false) do
      true -> {:reply, :ok, device}
      false ->
        Process.put(:to_notify_conn, from)
        {:noreply, device}
    end
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


  def handle_info(
        {:gun_up, conn_pid, _protocol},
        %GunDevice{
          conn_pid: conn_pid
        } = device
      ) do
    Logger.debug("Gun up")

    case Process.get(:to_notify_conn, false) do
      false -> Process.put(:is_gun_up, true)
      to_reply ->
        GenServer.reply(to_reply, :ok)
        Process.delete(:to_notify_conn)
    end

    {:noreply,
     device
     |> Device.do_inc_counter(:conn, 1) }#TODO: remove
#     |> Device.do_stop_timing(:conn)}
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
    device = %{device | conn_pid: nil, conn_ref: nil}
    {:noreply, device}
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

        :fin ->
          device |> complete_request()
      end

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
     device}
  end

  def handle_info(
        {:gun_error, conn_pid, reason},
        %GunDevice{
          conn_pid: conn_pid
        } = device
      ) do
    Logger.debug("Gun error #{inspect(reason)}")

    {:noreply, device}
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
     device}
  end

  def handle_info(
        message,
        device
      ) do
    Logger.debug("Unexpected message #{inspect(message)}")

    {:noreply, device}
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
        ws_upgraded: false,
        received_ws_frames: []
    }
  end

  defp connect(%GunDevice{address: {protocol, ip, port, host}} = device)
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

              {"application", "bert", _} ->
                {:bert, Bertex.safe_decode(IO.iodata_to_binary(response_iodata))}

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
    :closed_error
  end

  defp gun_reason_to_key(:closed) do
    :conn_lost_error
  end

  defp gun_reason_to_key({:shutdown, :econnrefused}) do
    :conn_refused_error
  end

  defp gun_reason_to_key({:shutdown, :econnreset}) do
    :conn_reset_error
  end

  defp gun_reason_to_key({:shutdown, :nxdomain}) do
    :nx_domain_error
  end

  defp gun_reason_to_key({:shutdown, :etimedout}) do
    :conn_timedout_error
  end

  defp gun_reason_to_key({:shutdown, :eaddrnotavail}) do
    :addr_not_avail_error
  end

  defp gun_reason_to_key({:shutdown, :ehostdown}) do
    :host_down_error
  end

  defp gun_reason_to_key({:shutdown, :ehostunreach}) do
    :host_unreach_error
  end

  defp gun_reason_to_key({:shutdown, :emfile}) do
    :too_many_open_files_error
  end

  defp gun_reason_to_key({:shutdown, :closed}) do
    :conn_lost_error
  end

  defp gun_reason_to_key({:shutdown, {:tls_alert, _}}) do
    :tls_alert_error
  end

  defp gun_reason_to_key({:stream_error, _, _}) do
    :http2_stream_error
  end

  defp gun_reason_to_key({:closed, _}) do
    :conn_lost_error
  end

  defp gun_reason_to_key({:badstate, _}) do
    :bad_conn_state_error
  end

  defp gun_reason_to_key(:noproc) do
    :conn_terminated_error
  end

  defp gun_reason_to_key(reason) do
    Logger.error("Gun error #{inspect(reason)}")

    :unknown_error
  end

  defp prepare_request(headers, body) when is_binary(body) do
    {:ok, headers, body}
  end

  defp prepare_request(headers, {:json, json}) do
    case Jason.encode(json) do
      {:ok, body} ->
        {:ok, add_content_type_to_headers(headers, "application/json; charset=utf-8"), body}

      error ->
        error
    end
  end

  defp prepare_request(headers, {:bert, bert}) do
    {:ok, add_content_type_to_headers(headers, "application/bert"), Bertex.encode(bert)}
  end

  defp add_host_to_headers(headers, host) do
    headers
    |> Enum.reject(fn
      {"host", _} -> true
      {"Host", _} -> true
      _ -> false
    end)
    |> Enum.concat([{"host", host}])
  end

  defp add_content_type_to_headers(headers, content_type) do
    headers
    |> Enum.reject(fn
      {"content-type", _} -> true
      {"Content-Type", _} -> true
      _ -> false
    end)
    |> Enum.concat([{"content-type", content_type}])
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
