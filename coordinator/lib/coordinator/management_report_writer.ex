defmodule Stressgrid.Coordinator.ManagementReportWriter do
  @moduledoc false

  alias Stressgrid.Coordinator.{Management, ReportWriter, ManagementReportWriter}

  @behaviour ReportWriter

  @max_history_size 60

  defstruct stats_history: %{}

  def init() do
    %ManagementReportWriter{}
  end

  def write(_, _, %ManagementReportWriter{stats_history: stats_history} = writer, hists, scalars) do
    stats =
      hists
      |> Enum.filter(fn {_, hist} ->
        :hdr_histogram.get_total_count(hist) != 0
      end)
      |> Enum.map(fn {key, hist} ->
        {key, :hdr_histogram.mean(hist)}
      end)
      |> Enum.concat(scalars)
      |> Map.new()

    missing_keys = Map.keys(stats_history) -- Map.keys(stats)

    stats_history =
      stats
      |> Enum.map(fn {key, value} ->
        values =
          case Map.get(stats_history, key) do
            nil ->
              [value]

            values ->
              Enum.take([value | values], @max_history_size)
          end

        {key, values}
      end)
      |> Enum.concat(
        Enum.map(missing_keys, fn missing_key ->
          values = Map.get(stats_history, missing_key)
          values = Enum.take([nil | values], @max_history_size)

          {missing_key, values}
        end)
      )
      |> Map.new()

    :ok = Management.notify_all(%{"stats" => stats_history})

    %{writer | stats_history: stats_history}
  end

  def finish(result_info, _, _) do
    :ok = Management.notify_all(%{"stats" => nil})

    result_info
  end
end
