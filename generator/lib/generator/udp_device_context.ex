defmodule Stressgrid.Generator.UdpDeviceContext do
  @moduledoc false

  alias Stressgrid.Generator.{UdpDevice}

  defmacro send(datagram) do
    quote do
      UdpDevice.send(var!(device_pid), unquote(datagram))
    end
  end

  defmacro recv(timeout \\ 5000) do
    quote do
      UdpDevice.recv(var!(device_pid), unquote(timeout))
    end
  end
end
