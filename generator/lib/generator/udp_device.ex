defmodule Stressgrid.Generator.UdpDevice do
  @moduledoc false

  alias Stressgrid.Generator.{
    Device,
    DeviceContext,
    UdpDevice,
    UdpDeviceContext
  }

  use GenServer

  use Device,
    device_functions:
      {DeviceContext,
       [
         delay: 1,
         delay: 2
       ]
       |> Enum.sort()},
    device_macros:
      {UdpDeviceContext,
       [
         send: 1
       ]
       |> Enum.sort()}

  require Logger

  defstruct address: nil,
            socket: nil

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

  def handle_call(
        {:send, datagram},
        _,
        %UdpDevice{address: {:udp, host, port}, socket: socket} = device
      ) do
    Logger.debug("Sending UDP datagram to #{host}:#{port}")

    device =
      case :gen_udp.send(socket, host |> String.to_charlist(), port, datagram) do
        :ok ->
          device
          |> Device.inc_counter("datagram_count" |> String.to_atom(), 1)

        {:error, reason} ->
          device
          |> Device.inc_counter(reason |> udp_reason_to_key(), 1)
      end

    {:reply, :ok, device}
  end

  def handle_info(
        :open,
        %UdpDevice{} = device
      ) do
    Logger.debug("Open UDP socket")

    device =
      case :gen_udp.open(0) do
        {:ok, socket} ->
          %{device | socket: socket} |> Device.start_task()

        {:error, reason} ->
          device
          |> Device.recycle(true)
          |> Device.inc_counter(reason |> udp_reason_to_key(), 1)
      end

    {:noreply, device}
  end

  def handle_info(
        :recycled,
        %UdpDevice{} = device
      ) do
    {:noreply, device}
  end

  def handle_info(
        _,
        device
      ) do
    {:noreply, device}
  end

  defp udp_reason_to_key(:nxdomain) do
    :nx_domain_error_count
  end

  defp udp_reason_to_key(:eaddrnotavail) do
    :addr_not_avail_error_count
  end

  defp udp_reason_to_key(:ehostdown) do
    :host_down_error_count
  end

  defp udp_reason_to_key(:ehostunreach) do
    :host_unreach_error_count
  end

  defp udp_reason_to_key(:emfile) do
    :too_many_open_files_error_count
  end

  defp udp_reason_to_key(reason) do
    Logger.error("UDP error #{inspect(reason)}")

    :unknown_error_count
  end
end
