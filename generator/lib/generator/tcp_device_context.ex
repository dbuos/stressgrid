defmodule Stressgrid.Generator.TcpDeviceContext do
  @moduledoc false

  alias Stressgrid.Generator.{TcpDevice}

  defmacro send(data) do
    quote do
      TcpDevice.send(var!(device_pid), unquote(data))
    end
  end

  defmacro recv(timeout \\ 5000) do
    quote do
      TcpDevice.recv(var!(device_pid), unquote(timeout))
    end
  end
end
