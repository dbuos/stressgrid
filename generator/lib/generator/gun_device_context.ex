defmodule Stressgrid.Generator.GunDeviceContext do
  @moduledoc false

  alias Stressgrid.Generator.{GunDevice}

  defmacro head(path, headers \\ []) do
    quote do
      GunDevice.request(var!(device_pid), "HEAD", unquote(path), unquote(headers), "")
    end
  end

  defmacro get(path, headers \\ []) do
    quote do
      GunDevice.request(var!(device_pid), "GET", unquote(path), unquote(headers), "")
    end
  end

  defmacro options(path, headers \\ []) do
    quote do
      GunDevice.request(var!(device_pid), "OPTIONS", unquote(path), unquote(headers), "")
    end
  end

  defmacro post(path, headers \\ [], body \\ "") do
    quote do
      GunDevice.request(var!(device_pid), "POST", unquote(path), unquote(headers), unquote(body))
    end
  end

  defmacro put(path, headers \\ [], body \\ "") do
    quote do
      GunDevice.request(var!(device_pid), "PUT", unquote(path), unquote(headers), unquote(body))
    end
  end

  defmacro patch(path, headers \\ [], body \\ "") do
    quote do
      GunDevice.request(var!(device_pid), "PATCH", unquote(path), unquote(headers), unquote(body))
    end
  end

  defmacro delete(path, headers \\ []) do
    quote do
      GunDevice.request(var!(device_pid), "DELETE", unquote(path), unquote(headers), "")
    end
  end

  defmacro ws_upgrade(path, headers \\ []) do
    quote do
      GunDevice.ws_upgrade(var!(device_pid), unquote(path), unquote(headers))
    end
  end

  defmacro ws_send(frame) do
    quote do
      GunDevice.ws_send(var!(device_pid), unquote(frame))
    end
  end

  defmacro ws_send_text(text) do
    quote do
      ws_send({:text, unquote(text)})
    end
  end

  defmacro ws_send_binary(binary) do
    quote do
      ws_send({:binary, unquote(binary)})
    end
  end
end
