defmodule Stressgrid.Coordinator.ReportWriter do
  @callback write_hists(String.t(), Integer.t(), Writer.t(), List.t()) :: Writer.t()
  @callback write_scalars(String.t(), Integer.t(), Writer.t(), List.t()) :: Writer.t()
  @callback write_basics(String.t(), Integer.t(), Writer.t(), List.t()) :: Writer.t()
  @callback finish(Map.t(), String.t(), Writer.t()) :: Map.t()
end
