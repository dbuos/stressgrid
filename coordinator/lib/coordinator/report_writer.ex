defmodule Stressgrid.Coordinator.ReportWriter do
  @callback write_hists(binary(), integer(), any(), list()) :: any()
  @callback write_scalars(binary(), integer(), any(), list()) :: any()
  @callback write_generator_telemetries(binary(), integer(), any(), list()) ::
              any()
  @callback finish(map(), binary(), any()) :: map()
end
