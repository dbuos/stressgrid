defmodule Stressgrid.Coordinator.Histogram do
  require Logger

  def record(hists, key, value) do
    {hists, hist} = ensure(hists, key)

    :hdr_histogram.record(hist, value)
    hists
  end

  def add(to_hists, from_hists) do
    Enum.reduce(from_hists, to_hists, fn {key, from_hist}, hists ->
      {hists, to_hist} = ensure(hists, key)

      :ok =
        case :hdr_histogram.add(to_hist, from_hist) do
          dropped_count when is_integer(dropped_count) ->
            :ok

          {:error, error} ->
            Logger.error("Error adding hists #{inspect(error)}")
            :ok
        end

      hists
    end)
  end

  defp ensure(hists, key) do
    case Map.get(hists, key) do
      nil ->
        hist = make()
        {Map.put(hists, key, hist), hist}

      hist ->
        {hists, hist}
    end
  end

  defp make do
    {:ok, hist} = :hdr_histogram.open(60_000_000, 3)
    hist
  end
end
