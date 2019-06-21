defmodule Stressgrid.Generator.Device.Supervisor do
  @moduledoc false

  use DynamicSupervisor

  alias Stressgrid.Generator.{GunDevice, TcpDevice, UdpDevice}

  def start_link([]) do
    DynamicSupervisor.start_link(__MODULE__, [])
  end

  def start_child(cohort_pid, id, address, script, params) do
    DynamicSupervisor.start_child(
      cohort_pid,
      {address_module(address), id: id, address: address, script: script, params: params}
    )
  end

  def init(_) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp address_module({:http, _, _, _}), do: GunDevice
  defp address_module({:https, _, _, _}), do: GunDevice
  defp address_module({:http2, _, _, _}), do: GunDevice
  defp address_module({:http2s, _, _, _}), do: GunDevice
  defp address_module({:tcp, _, _, _}), do: TcpDevice
  defp address_module({:udp, _, _, _}), do: UdpDevice
end
