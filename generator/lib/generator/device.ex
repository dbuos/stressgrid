defmodule Stressgrid.Generator.Device do
  @moduledoc false

  alias Stressgrid.Generator.{Device}

  require Logger

  defstruct task_fn: nil,
            task: nil,
            script_error: nil,
            hists: %{},
            counters: %{}

  defmacro __using__(opts) do
    device_functions = opts |> Keyword.fetch!(:device_functions)
    device_macros = opts |> Keyword.fetch!(:device_macros)

    quote do
      alias Stressgrid.Generator.{Device}

      def handle_call(
            {:collect, to_hists},
            _,
            state
          ) do
        {r, state} = state |> Device.do_collect(to_hists)
        {:reply, r, state}
      end

      def handle_info({:init, id, task_script, task_params}, state) do
        {:noreply,
         state
         |> Device.do_init(
           id,
           task_script,
           task_params,
           unquote(device_functions),
           unquote(device_macros)
         )}
      end

      def handle_info(
            {task_ref, :ok},
            %{device: %Device{task: %Task{ref: task_ref}} = device} = state
          )
          when is_reference(task_ref) do
        {:noreply, state |> Device.do_task_completed()}
      end

      def handle_info(
            {:DOWN, task_ref, :process, task_pid, reason},
            %{
              device:
                %Device{
                  task: %Task{
                    ref: task_ref,
                    pid: task_pid
                  }
                } = device
            } = state
          ) do
        {:noreply, state |> Device.do_task_down(reason)}
      end
    end
  end

  @recycle_delay 1_000

  def collect(pid, to_hists) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:collect, to_hists})
    else
      {:ok, nil, false, %{}, %{}}
    end
  end

  def init(state, args) do
    id = args |> Keyword.fetch!(:id)
    task_script = args |> Keyword.fetch!(:script)
    task_params = args |> Keyword.fetch!(:params)

    _ = Kernel.send(self(), {:init, id, task_script, task_params})

    state
    |> Map.put(:device, %Device{})
  end

  def do_collect(
        %{
          device:
            %Device{script_error: script_error, hists: from_hists, counters: counters, task: task} =
              device
        } = state,
        to_hists
      ) do
    hists = add_hists(to_hists, from_hists)

    :ok =
      from_hists
      |> Enum.each(fn {_, hist} ->
        :ok = :hdr_histogram.reset(hist)
      end)

    reset_counters =
      counters
      |> Enum.map(fn {key, _} -> {key, 0} end)
      |> Map.new()

    {{:ok, script_error, task != nil, hists, counters},
     %{state | device: %{device | counters: reset_counters}}}
  end

  def do_init(
        %{device: device} = state,
        id,
        task_script,
        task_params,
        device_functions,
        device_macros
      ) do
    Logger.debug("Init device #{id}")

    %Macro.Env{functions: functions, macros: macros} = __ENV__

    kernel_functions =
      functions
      |> Enum.find(fn
        {Kernel, _} -> true
        _ -> false
      end)

    kernel_macros =
      macros
      |> Enum.find(fn
        {Kernel, _} -> true
        _ -> false
      end)

    device_pid = self()

    try do
      {task_fn, _} =
        "fn -> #{task_script} end"
        |> Code.eval_string([device_pid: device_pid, params: task_params],
          functions: [
            kernel_functions,
            device_functions
          ],
          macros: [
            kernel_macros,
            device_macros
          ]
        )

      _ = Kernel.send(self(), :open)

      %{
        state
        | device: %{
            device
            | task_fn: task_fn,
              hists: %{
                conn_us: make_hist(),
                headers_us: make_hist(),
                body_us: make_hist()
              }
          }
      }
    catch
      :error, error ->
        %{state | device: %{device | script_error: %{error: error, script: task_script}}}
    end
  end

  def start_task(%{device: %Device{task_fn: task_fn} = device} = state) do
    task =
      %Task{pid: task_pid} =
      Task.async(fn ->
        try do
          task_fn.()
        catch
          :exit, :device_terminated ->
            :ok
        end

        :ok
      end)

    true = Process.unlink(task_pid)

    %{state | device: %{device | task: task}}
  end

  def do_task_completed(%{device: %Device{task: %Task{ref: task_ref}} = device} = state) do
    Logger.debug("Script exited normally")

    true = Process.demonitor(task_ref, [:flush])

    state |> recycle()
  end

  def do_task_down(
        state,
        reason
      ) do
    state
    |> recycle(true)
    |> inc_counter(reason |> task_reason_to_key(), 1)
  end

  def recycle(
        %{device: %Device{task: task} = device} = state,
        delay \\ false
      ) do
    Logger.debug("Recycle device")

    if task != nil do
      Task.shutdown(task, :brutal_kill)
    end

    _ = Kernel.send(self(), :recycled)
    _ = Process.send_after(self(), :open, if(delay, do: @recycle_delay, else: 0))

    %{state | device: %{device | task: nil}}
  end

  def record_hist(%{device: %Device{hists: hists} = device} = state, key, value) do
    {device, hist} =
      case hists |> Map.get(key) do
        nil ->
          hist = make_hist()
          {%{device | hists: hists |> Map.put(key, hist)}, hist}

        hist ->
          {device, hist}
      end

    :hdr_histogram.record(hist, value)
    %{state | device: device}
  end

  def inc_counter(%{device: %Device{counters: counters} = device} = state, key, value) do
    %{
      state
      | device: %{
          device
          | counters:
              counters
              |> Map.update(key, value, fn c -> c + value end)
        }
    }
  end

  defp add_hists(to_hists, from_hists) do
    from_hists
    |> Enum.reduce(to_hists, fn {key, from_hist}, hists ->
      {hists, to_hist} =
        case hists
             |> Map.get(key) do
          nil ->
            hist = make_hist()
            {hists |> Map.put(key, hist), hist}

          hist ->
            {hists, hist}
        end

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

  defp make_hist do
    {:ok, hist} = :hdr_histogram.open(60_000_000, 3)
    hist
  end

  defp task_reason_to_key({:timeout, {GenServer, :call, _}}) do
    Logger.debug("Script timeout")

    :timeout_task_error_count
  end

  defp task_reason_to_key(reason) do
    Logger.error("Script error #{inspect(reason)}")

    :unknown_task_error_count
  end
end
