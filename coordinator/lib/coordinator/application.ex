defmodule Stressgrid.Coordinator.Application do
  @moduledoc false

  use Application
  require Logger

  alias Stressgrid.Coordinator.{
    GeneratorConnection,
    GeneratorRegistry,
    Reporter,
    Scheduler,
    CsvReportWriter,
    CloudWatchReportWriter,
    Management,
    ManagementConnection,
    ManagementReportWriter
  }

  @management_report_writer_interval_ms 1_000
  @default_report_interval_seconds 60
  @default_generators_port 9696
  @default_management_port 8000

  def start(_type, _args) do
    generators_port = get_env_integer("GENERATORS_PORT", @default_generators_port)
    management_port = get_env_integer("MANAGEMENT_PORT", @default_management_port)

    report_interval_ms =
      get_env_integer("REPORT_INTERVAL_SECONDS", @default_report_interval_seconds) * 1000

    writer_configs = [
      {CsvReportWriter, [], report_interval_ms},
      {CloudWatchReportWriter, [], report_interval_ms},
      {ManagementReportWriter, [], @management_report_writer_interval_ms}
    ]

    children = [
      Management.registry_spec(),
      Management,
      GeneratorRegistry,
      {Reporter, writer_configs: writer_configs},
      Scheduler,
      cowboy_sup(:generators_listener, generators_port, generators_dispatch()),
      cowboy_sup(:management_listener, management_port, management_dispatch())
    ]

    Logger.info("Listening for generators on port #{generators_port}")
    Logger.info("Listening for management on port #{management_port}")

    opts = [strategy: :one_for_one, name: Stressgrid.Coordinator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp cowboy_sup(id, port, dispatch) do
    %{
      id: id,
      start: {:cowboy, :start_clear, [id, [port: port], %{env: %{dispatch: dispatch}}]},
      restart: :permanent,
      shutdown: :infinity,
      type: :supervisor
    }
  end

  defp generators_dispatch do
    :cowboy_router.compile([{:_, [{"/", GeneratorConnection, %{}}]}])
  end

  defp management_dispatch do
    :cowboy_router.compile([
      {:_,
       [
         {"/", :cowboy_static,
          {:priv_file, :coordinator, "management/index.html",
           [{:mimetypes, :cow_mimetypes, :all}]}},
         {"/ws", ManagementConnection, %{}},
         {"/[...]", :cowboy_static,
          {:priv_dir, :coordinator, "management", [{:mimetypes, :cow_mimetypes, :all}]}}
       ]}
    ])
  end

  defp get_env_integer(name, default) do
    case Map.get(System.get_env(), name) do
      nil ->
        default

      value ->
        String.to_integer(value)
    end
  end
end
