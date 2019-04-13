defmodule Stressgrid.Generator.DeviceContext do
  @moduledoc false

  def delay(milliseconds, deviation_ratio \\ 0)
      when deviation_ratio >= 0 and deviation_ratio < 1 do
    deviation = milliseconds * deviation_ratio
    Process.sleep(trunc(milliseconds + deviation / 2 - deviation * :rand.uniform()))
  end
end
