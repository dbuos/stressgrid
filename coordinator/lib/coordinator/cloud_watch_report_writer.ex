defmodule Stressgrid.Coordinator.CloudWatchReportWriter do
  @moduledoc false

  alias Stressgrid.Coordinator.{ReportWriter, CloudWatchReportWriter}

  @meta_data_placement_availability_zone "http://169.254.169.254/latest/meta-data/placement/availability-zone"
  @behaviour ReportWriter

  require Logger

  defstruct region: nil

  def init(_) do
    %CloudWatchReportWriter{region: detect_ec2_region()}
  end

  def start(writer) do
    writer
  end

  def write(_, _, %CloudWatchReportWriter{region: nil} = writer, _, _), do: writer

  def write(id, _, %CloudWatchReportWriter{region: region} = writer, hists, scalars) do
    :ok =
      put_metric_data(
        region,
        hists
        |> Enum.reduce([], fn {key, hist}, acc ->
          if :hdr_histogram.get_total_count(hist) != 0 do
            count = :hdr_histogram.get_total_count(hist)
            sum = :hdr_histogram.mean(hist) * count
            max = :hdr_histogram.max(hist)
            min = :hdr_histogram.min(hist)
            [{:statistic, key, key_unit(key), count, sum, max, min, [run: id]} | acc]
          else
            acc
          end
        end)
      )

    :ok =
      put_metric_data(
        region,
        scalars
        |> Enum.map(fn {key, value} ->
          {:scalar, key, key_unit(key), value, [run: id]}
        end)
      )

    writer
  end

  def finish(result_info, _, %CloudWatchReportWriter{region: nil}), do: result_info

  def finish(result_info, id, %CloudWatchReportWriter{region: region}) do
    cw_url =
      "https://#{region}.console.aws.amazon.com/cloudwatch/home" <>
        "?region=#{region}#metricsV2:graph=~();search=#{id}"

    result_info |> Map.merge(%{"cw_url" => cw_url})
  end

  defp put_metric_data(_, []) do
    :ok
  end

  defp put_metric_data(region, datum) do
    params = %{
      "Action" => "PutMetricData",
      "Version" => "2010-08-01",
      "Namespace" => "Stressgrid"
    }

    {_, params} =
      datum
      |> Enum.reduce({1, params}, fn
        {:scalar, name, unit, value, dims}, {i, params} ->
          prefix = "MetricData.member.#{i}"

          params =
            params
            |> Map.merge(%{
              "#{prefix}.MetricName" => name |> Atom.to_string() |> Macro.camelize(),
              "#{prefix}.Unit" => unit_to_data(unit),
              "#{prefix}.Value" => value
            })

          {i + 1,
           params
           |> Map.merge(dim_params(prefix, dims))}

        {:statistic, name, unit, count, sum, max, min, dims}, {i, params} ->
          prefix = "MetricData.member.#{i}"

          params =
            params
            |> Map.merge(%{
              "#{prefix}.MetricName" => name |> Atom.to_string() |> Macro.camelize(),
              "#{prefix}.Unit" => unit_to_data(unit),
              "#{prefix}.StatisticValues.SampleCount" => count,
              "#{prefix}.StatisticValues.Sum" => sum,
              "#{prefix}.StatisticValues.Maximum" => max,
              "#{prefix}.StatisticValues.Minimum" => min
            })

          {i + 1,
           params
           |> Map.merge(dim_params(prefix, dims))}
      end)

    Task.start(fn ->
      case %ExAws.Operation.Query{
             path: "/",
             params: params,
             service: :monitoring,
             action: :put_metric_data,
             parser: &ExAws.Cloudwatch.Parsers.parse/2
           }
           |> ExAws.request(region: region) do
        {:ok, _} ->
          Logger.debug("CloudWatch written successfully")

        {:error, error} ->
          Logger.error("CloudWatch error writing #{inspect(error)}")
      end
    end)

    :ok
  end

  defp dim_params(prefix, dims) do
    {_, dim_params} =
      dims
      |> Enum.reduce({1, %{}}, fn {name, value}, {k, params} ->
        dim_prefix = "#{prefix}.Dimensions.member.#{k}"

        {k + 1,
         params
         |> Map.merge(%{
           "#{dim_prefix}.Name" => name |> Atom.to_string() |> Macro.camelize(),
           "#{dim_prefix}.Value" => value
         })}
      end)

    dim_params
  end

  defp unit_to_data(:count), do: "Count"
  defp unit_to_data(:count_per_second), do: "Count/Second"
  defp unit_to_data(:percent), do: "Percent"
  defp unit_to_data(:us), do: "Microseconds"

  defp key_unit(key) do
    key_s = key |> Atom.to_string()

    if Regex.match?(~r/count_per_second$/, key_s) do
      :count_per_second
    else
      if Regex.match?(~r/count$/, key_s) do
        :count
      else
        if Regex.match?(~r/us$/, key_s) do
          :us
        else
          :count
        end
      end
    end
  end

  defp detect_ec2_region do
    case Map.get(System.get_env(), "AWS_REGION") do
      nil ->
        with {:ok, %HTTPoison.Response{body: body}} <-
               HTTPoison.get(@meta_data_placement_availability_zone),
             [_, region] <- Regex.run(~r/(.*)[a-z]$/, body) do
          region
        else
          _ ->
            nil
        end

      region ->
        region
    end
  end
end
