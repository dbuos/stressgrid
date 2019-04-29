defmodule Stressgrid.Generator.TcpDevice do
  @moduledoc false

  alias Stressgrid.Generator.{
    Device,
    TcpDevice,
    TcpDeviceContext
  }

  use GenServer

  use Device,
    device_macros: [
      {TcpDeviceContext,
       [
         send: 1,
         recv: 0,
         recv: 1
       ]
       |> Enum.sort()}
    ]

  require Logger

  @max_received_iodata_size 65_536

  defstruct address: nil,
            socket: nil,
            waiting_receive_froms: [],
            received_iodata: []

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    {:ok, %TcpDevice{address: args |> Keyword.fetch!(:address)} |> Device.init(args)}
  end

  def send(pid, data) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:send, data})
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
        {:send, _},
        _,
        %TcpDevice{socket: nil} = device
      ) do
    {:reply, {:error, :closed}, device}
  end

  def handle_call(
        {:send, data},
        _,
        %TcpDevice{socket: socket} = device
      ) do
    Logger.debug("Sending TCP data")

    device =
      case :gen_tcp.send(socket, data) do
        :ok ->
          device

        {:error, reason} ->
          device
          |> Device.inc_counter(reason |> tcp_reason_to_key(), 1)
      end

    {:reply, :ok, device}
  end

  def handle_call(
        :receive,
        _,
        %TcpDevice{socket: nil, received_iodata: []} = device
      ) do
    {:reply, {:error, :closed}, device}
  end

  def handle_call(
        :receive,
        receive_from,
        %TcpDevice{received_iodata: [], waiting_receive_froms: waiting_receive_froms} = device
      ) do
    {:noreply, %{device | waiting_receive_froms: waiting_receive_froms ++ [receive_from]}}
  end

  def handle_call(
        :receive,
        _,
        %TcpDevice{received_iodata: iodata} = device
      ) do
    {:reply, {:ok, iodata}, %{device | received_iodata: []}}
  end

  def handle_info(
        :open,
        %TcpDevice{address: {:tcp, host, port}} = device
      ) do
    Logger.debug("Open TCP socket")

    device =
      case :gen_tcp.connect(host |> String.to_charlist(), port, [{:mode, :binary}]) do
        {:ok, socket} ->
          %{device | socket: socket} |> Device.start_task()

        {:error, reason} ->
          device
          |> Device.recycle(true)
          |> Device.inc_counter(reason |> tcp_reason_to_key(), 1)
      end

    {:noreply, device}
  end

  def handle_info(
        :recycled,
        %TcpDevice{socket: socket} = device
      ) do
    if socket != nil do
      :gen_tcp.close(socket)
    end

    {:noreply, %{device | socket: nil, received_iodata: [], waiting_receive_froms: []}}
  end

  def handle_info(
        {:tcp, socket, data},
        %TcpDevice{
          socket: socket,
          waiting_receive_froms: [],
          received_iodata: received_iodata
        } = device
      ) do
    if received_iodata |> Enum.map(&byte_size(&1)) |> Enum.sum() > @max_received_iodata_size do
      Logger.debug("Discarded TCP data")

      {:noreply, device}
    else
      Logger.debug("Received TCP data")

      {:noreply, %{device | received_iodata: received_iodata ++ [data]}}
    end
  end

  def handle_info(
        {:tcp_closed, socket},
        %TcpDevice{
          socket: socket
        } = device
      ) do
    Logger.debug("TCP socket closed")

    {:noreply, %{device | socket: nil}}
  end

  def handle_info(
        {:tcp_error, socket, reason},
        %TcpDevice{
          socket: socket
        } = device
      ) do
    {:noreply,
     device
     |> Device.recycle(true)
     |> Device.inc_counter(reason |> tcp_reason_to_key(), 1)}
  end

  def handle_info(
        {:tcp, socket, data},
        %TcpDevice{socket: socket, waiting_receive_froms: [receive_from | waiting_receive_froms]} =
          device
      ) do
    Logger.debug("Received TCP data for waiting receive")
    GenServer.reply(receive_from, {:ok, [data]})
    {:noreply, %{device | waiting_receive_froms: waiting_receive_froms}}
  end

  def handle_info(
        _,
        device
      ) do
    {:noreply, device}
  end

  defp tcp_reason_to_key(:nxdomain) do
    :nx_domain_error_count
  end

  defp tcp_reason_to_key(:eaddrnotavail) do
    :addr_not_avail_error_count
  end

  defp tcp_reason_to_key(:ehostdown) do
    :host_down_error_count
  end

  defp tcp_reason_to_key(:ehostunreach) do
    :host_unreach_error_count
  end

  defp tcp_reason_to_key(:emfile) do
    :too_many_open_files_error_count
  end

  defp tcp_reason_to_key(reason) do
    Logger.error("TCP error #{inspect(reason)}")

    :unknown_error_count
  end
end
