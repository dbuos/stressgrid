defmodule Stressgrid.Coordinator.Scheduler do
  @moduledoc false

  use GenServer
  require Logger

  alias Stressgrid.Coordinator.{
    Scheduler,
    Utils,
    GeneratorRegistry,
    Reporter
  }

  @cooldown_ms 60_000

  defmodule Run do
    defstruct id: nil,
              plan_name: nil,
              state: nil,
              until_ms: 0,
              timer_refs: [],
              cohort_ids: []
  end

  defstruct run: nil

  def start_run(plan_name, blocks, addresses, opts \\ []) do
    GenServer.cast(__MODULE__, {:start_run, plan_name, blocks, addresses, opts})
  end

  def abort_run do
    GenServer.cast(__MODULE__, :abort_run)
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def get_run_json() do
    GenServer.call(__MODULE__, :get_run_json)
  end

  def init(_args) do
    {:ok, %Scheduler{}}
  end

  def handle_call(:get_run_json, _, %Scheduler{run: nil} = scheduler) do
    {:reply, :no_run, scheduler}
  end

  def handle_call(:get_run_json, _, %Scheduler{run: run} = scheduler) do
    run_json = run_to_json(run)

    {:reply, {:ok, run_json}, scheduler}
  end

  def handle_info({:run_op, op}, %Scheduler{run: run} = scheduler) do
    if run != nil do
      run = run |> do_run_op(op)

      {:noreply, %{scheduler | run: run}}
    else
      {:noreply, scheduler}
    end
  end

  def handle_info(
        {:run_state_change, state, remaining_ms},
        %Scheduler{run: run} = scheduler
      ) do
    if run != nil do
      run = run |> do_run_state_change(state, remaining_ms)

      {:noreply, %{scheduler | run: run}}
    else
      {:noreply, scheduler}
    end
  end

  def handle_cast(:abort_run, %Scheduler{run: run} = scheduler) do
    :ok = do_abort_run(run)

    {:noreply, %{scheduler | run: nil}}
  end

  def handle_cast(
        {:start_run, plan_name, blocks, addresses, opts},
        %Scheduler{run: run} = scheduler
      ) do
    :ok = do_abort_run(run)

    {:noreply, %{scheduler | run: schedule_run(plan_name, blocks, addresses, opts)}}
  end

  defp schedule_run(plan_name, blocks, addresses, opts) do
    safe_name =
      plan_name
      |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
      |> String.trim("-")

    now =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/[TZ\.]/, "")

    id = "#{safe_name}-#{now}"

    ramp_steps = opts |> Keyword.get(:ramp_steps, 100)
    rampup_step_ms = opts |> Keyword.get(:rampup_step_ms, 1000)
    sustain_ms = opts |> Keyword.get(:sustain_ms, 300_000)
    rampdown_step_ms = opts |> Keyword.get(:rampdown_step_ms, rampup_step_ms)

    ts = 0
    timer_refs = [schedule_state_change(ts, :rampup, ramp_steps * rampup_step_ms)]
    timer_refs = [schedule_op(ts, :start) | timer_refs]

    {ts, timer_refs} =
      1..ramp_steps
      |> Enum.zip(blocks |> Utils.split_blocks(ramp_steps))
      |> Enum.reduce({ts, timer_refs}, fn {i, blocks}, {ts, timer_refs} ->
        {ts + rampup_step_ms,
         [schedule_op(ts, {:start_cohort, "#{id}-#{i - 1}", blocks, addresses}) | timer_refs]}
      end)

    timer_refs = [schedule_state_change(ts, :sustain, sustain_ms) | timer_refs]
    ts = ts + sustain_ms

    timer_refs = [
      schedule_state_change(ts, :rampdown, ramp_steps * rampdown_step_ms)
      | timer_refs
    ]

    {ts, timer_refs} =
      ramp_steps..1
      |> Enum.reduce({ts, timer_refs}, fn i, {ts, timer_refs} ->
        {ts + rampdown_step_ms, [schedule_op(ts, {:stop_cohort, "#{id}-#{i - 1}"}) | timer_refs]}
      end)

    timer_refs = [schedule_state_change(ts, :cooldown, @cooldown_ms) | timer_refs]
    ts = ts + @cooldown_ms

    timer_refs = [schedule_op(ts, :stop) | timer_refs]

    %Run{id: id, plan_name: plan_name, timer_refs: timer_refs, state: :init}
  end

  defp schedule_op(ts, op) do
    Logger.info("Operation #{inspect(op)} at #{ts}")

    Process.send_after(
      self(),
      {:run_op, op},
      ts
    )
  end

  defp schedule_state_change(ts, state, remaining_ms) do
    Process.send_after(
      self(),
      {:run_state_change, state, remaining_ms},
      ts
    )
  end

  defp do_abort_run(nil) do
    :ok
  end

  defp do_abort_run(%Run{id: id, timer_refs: timer_refs, cohort_ids: cohort_ids}) do
    Logger.info("Aborted run #{id}")

    :ok =
      timer_refs
      |> Enum.each(&Process.cancel_timer(&1))

    :ok =
      cohort_ids
      |> Enum.each(&GeneratorRegistry.stop_cohort(&1))

    :ok = Reporter.stop_run()

    :ok
  end

  defp do_run_op(%Run{id: id, plan_name: plan_name} = run, :start) do
    Logger.info("Started run #{id}")
    :ok = Reporter.start_run(id, plan_name)
    run
  end

  defp do_run_op(%Run{id: id}, :stop) do
    Logger.info("Stopped run #{id}")
    :ok = Reporter.stop_run()
    nil
  end

  defp do_run_op(
         %Run{cohort_ids: cohort_ids} = run,
         {:start_cohort, cohort_id, blocks, addresses}
       ) do
    Logger.info("Started cohort #{cohort_id}")
    :ok = GeneratorRegistry.start_cohort(cohort_id, blocks, addresses)
    %{run | cohort_ids: [cohort_id | cohort_ids]}
  end

  defp do_run_op(%Run{cohort_ids: cohort_ids} = run, {:stop_cohort, cohort_id}) do
    Logger.info("Stopped cohort #{cohort_id}")
    :ok = GeneratorRegistry.stop_cohort(cohort_id)
    %{run | cohort_ids: cohort_ids |> List.delete(cohort_id)}
  end

  defp do_run_state_change(run, state, remaining_ms) do
    %{run | state: state, until_ms: now_ms() + remaining_ms}
  end

  defp now_ms do
    {mega_secs, secs, micro_secs} = :erlang.timestamp()
    mega_secs * 1_000_000_000 + secs * 1_000 + trunc(micro_secs / 1_000)
  end

  defp run_to_json(%Run{id: id, plan_name: plan_name, state: state, until_ms: until_ms}) do
    %{
      "id" => id,
      "name" => plan_name,
      "state" => state |> Atom.to_string(),
      "remaining_ms" => max(0, until_ms - now_ms())
    }
  end
end
