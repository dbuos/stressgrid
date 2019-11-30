defmodule Stressgrid.Coordinator.ReportWriter do
  @callback init(any()) :: any()
  @callback start(any()) :: any()
  @callback write(binary(), integer(), any(), list(), list()) :: any()
  @callback finish(map(), binary(), any()) :: map()
end
