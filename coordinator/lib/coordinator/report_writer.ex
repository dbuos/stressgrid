defmodule Stressgrid.Coordinator.ReportWriter do
  @callback write(binary(), integer(), any(), list(), list()) :: any()
  @callback finish(map(), binary(), any()) :: map()
end
