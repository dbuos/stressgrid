defmodule Stressgrid.Generator.DeviceContext do
  @moduledoc false

  alias Stressgrid.Generator.{Device}

  defmacro start_timing(key) do
    quote do
      Device.start_timing(var!(device_pid), unquote(key))
    end
  end

  defmacro stop_timing(key) do
    quote do
      Device.stop_timing(var!(device_pid), unquote(key))
    end
  end

  defmacro stop_start_timing(key, key) do
    quote do
      Device.stop_start_timing(var!(device_pid), unquote(key), unquote(key))
    end
  end

  defmacro stop_start_timing(stop_key, start_key) do
    quote do
      Device.stop_start_timing(var!(device_pid), unquote(stop_key), unquote(start_key))
    end
  end

  defmacro inc_counter(key, value \\ 1) do
    quote do
      Device.inc_counter(var!(device_pid), unquote(key), unquote(value))
    end
  end

  def delay(milliseconds, deviation_ratio \\ 0)
      when deviation_ratio >= 0 and deviation_ratio < 1 do
    deviation = milliseconds * deviation_ratio
    Process.sleep(trunc(milliseconds + deviation / 2 - deviation * :rand.uniform()))
  end

  def payload(size) do
    {:ok, random} = File.open("/dev/urandom", [:read])
    payload = IO.binread(random, size)
    :ok = File.close(random)
    payload
  end
end
