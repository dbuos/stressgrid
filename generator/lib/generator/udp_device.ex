defmodule Stressgrid.Generator.UdpDevice do
  @moduledoc false

  alias Stressgrid.Generator.{
    Device,
    UdpDevice,
    UdpDeviceContext
  }

  use GenServer

  use Device,
    device_macros: [
      {UdpDeviceContext,
       [
         send: 1,
         recv: 0,
         recv: 1
       ]
       |> Enum.sort()}
    ]

  require Logger

  @max_received_datagrams 1024

  defstruct address: nil,
            socket: nil,
            waiting_receive_froms: [],
            received_datagrams: []

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    {:ok, %UdpDevice{address: args |> Keyword.fetch!(:address)} |> Device.init(args)}
  end

  def send(pid, datagram) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:send, datagram})
    else
      exit(:device_terminated)
    end
  end

  def recv(pid, timeout) do
    if Process.alive?(pid) do
      GenServer.call(pid, :receive, timeout)
    else
      exit(:device_terminated)
    end
  end

  def handle_call(
        {:send, datagram},
        _,
        %UdpDevice{address: {:udp, ip, port, _}, socket: socket} = device
      ) do
    Logger.debug("Sending UDP datagram to #{:inet.ntoa(ip)}:#{port}")

    device =
      case :gen_udp.send(socket, ip, port, datagram) do
        :ok ->
          device
          |> Device.do_inc_counter(:datagram, 1)

        {:error, reason} ->
          device
          |> Device.do_inc_counter(reason |> udp_reason_to_key(), 1)
      end

    {:reply, :ok, device}
  end

  def handle_call(
        :receive,
        _,
        %UdpDevice{received_datagrams: [datagram | received_datagrams]} = device
      ) do
    {:reply, {:ok, datagram}, %{device | received_datagrams: received_datagrams}}
  end

  def handle_call(
        :receive,
        receive_from,
        %UdpDevice{waiting_receive_froms: waiting_receive_froms} = device
      ) do
    {:noreply, %{device | waiting_receive_froms: waiting_receive_froms ++ [receive_from]}}
  end

  def handle_info(
        {:udp, socket, ip, port, datagram},
        %UdpDevice{
          socket: socket,
          waiting_receive_froms: [],
          received_datagrams: received_datagrams
        } = device
      ) do
    if length(received_datagrams) > @max_received_datagrams do
      Logger.debug("Discarded UDP datagram from #{:inet.ntoa(ip)}:#{port}")

      {:noreply, device}
    else
      Logger.debug("Received UDP datagram from #{:inet.ntoa(ip)}:#{port}")

      {:noreply, %{device | received_datagrams: received_datagrams ++ [datagram]}}
    end
  end

  def handle_info(
        {:udp, socket, ip, port, datagram},
        %UdpDevice{socket: socket, waiting_receive_froms: [receive_from | waiting_receive_froms]} =
          device
      ) do
    Logger.debug("Received UDP datagram from #{:inet.ntoa(ip)}:#{port} for waiting receive")
    GenServer.reply(receive_from, {:ok, datagram})
    {:noreply, %{device | waiting_receive_froms: waiting_receive_froms}}
  end

  def handle_info(
        _,
        device
      ) do
    {:noreply, device}
  end

  def open(%UdpDevice{} = device) do
    Logger.debug("Open UDP socket")

    case :gen_udp.open(0, [{:mode, :binary}]) do
      {:ok, socket} ->
        %{device | socket: socket} |> Device.start_task()

      {:error, reason} ->
        device
        |> Device.recycle()
        |> Device.do_inc_counter(reason |> udp_reason_to_key(), 1)
    end
  end

  def close(%UdpDevice{socket: socket} = device) do
    if socket != nil do
      :gen_udp.close(socket)
    end

    %{device | socket: nil, received_datagrams: [], waiting_receive_froms: []}
  end

  defp udp_reason_to_key(:nxdomain) do
    :nx_domain_error
  end

  defp udp_reason_to_key(:eaddrnotavail) do
    :addr_not_avail_error
  end

  defp udp_reason_to_key(:ehostdown) do
    :host_down_error
  end

  defp udp_reason_to_key(:ehostunreach) do
    :host_unreach_error
  end

  defp udp_reason_to_key(:emfile) do
    :too_many_open_files_error
  end

  defp udp_reason_to_key(reason) do
    Logger.error("UDP error #{inspect(reason)}")

    :unknown_error
  end
end
