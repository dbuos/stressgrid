import _ from 'lodash';
import ReconnectingWebSocket from 'reconnecting-websocket';

export interface IScriptError {
  description: string;
  line: number;
}

export interface ITelemetry {
  cpu: number[];
  network_rx: number[];
  network_tx: number[];
  active_count: number[];
  last_errors?: Map<string, number[]>;
  last_script_error?: IScriptError;
  generator_count: number[];
}

export interface IRun {
  id: string;
  name: string;
  state: string;
  remaining_ms: number;
}

export interface IResult {
  csv_url?: string;
  cw_url?: string;
}

export interface IReport {
  id: string;
  name: string;
  errors?: Map<string, number[]>;
  script_error?: IScriptError;
  max_cpu: number;
  max_network_rx: number;
  max_network_tx: number;
  max_generator_count: number;
  result: IResult;
}

export interface IInit {
  reports: IReport[];
  grid: IGrid;
}

export interface IGrid {
  telemetry: ITelemetry;
  run: IRun | null;
}

export interface INotify {
  grid_changed?: IGrid;
  report_added?: IReport;
  report_removed?: { id: string };
}

export interface IBlock {
  script?: string;
  params?: object;
  size?: number;
}

export interface IAddress {
  host: string;
  port?: number;
  protocol?: string;
}

export interface IOpts {
  ramp_steps?: number;
  rampup_step_ms?: number;
  sustain_ms?: number;
  rampdown_step_ms?: number;
}

export interface IRunPlan {
  name: string;
  blocks: IBlock[];
  addresses: IAddress[];
  opts: IOpts;
  script?: string;
}

export interface IRemoveReport {
  id: string;
}

export interface IMessage {
  init?: IInit;
  notify?: INotify;
  run_plan?: IRunPlan;
  remove_report?: IRemoveReport;
}

export interface IStressgridEvents {
  init(grid: IGrid, reports: IReport[]): void;
  updateGrid(grid: IGrid): void;
  addReport(report: IReport): void;
  deleteReport(id: string): void;
  disconnected(): void;
}

export class Stressgrid {
  private ws: ReconnectingWebSocket;
  private events: IStressgridEvents;

  constructor(events: IStressgridEvents) {
    this.events = events;
  }

  public connect(wsUrl: string, WebSocket?: any) {
    this.ws = new ReconnectingWebSocket(wsUrl, [], {
      WebSocket
    });
    this.ws.onmessage = (e) => {
      _.each(JSON.parse(e.data), (message: IMessage) => {
        this.handle(message);
      });
    }
    this.ws.onclose = (e) => {
      this.events.disconnected();
    }
  }

  public disconnect() {
    this.ws.close();
    this.ws.onmessage = undefined;
  }

  public run(runPlan: IRunPlan) {
    this.send([{
      run_plan: runPlan
    }]);
  }

  public abortRun() {
    this.send(['abort_run']);
  }

  public removeReport(id: string) {
    this.send([{
      remove_report: {
        id
      }
    }]);
  }

  private send(messages: Array<IMessage | string>) {
    this.ws.send(JSON.stringify(messages));
  }

  private handle(message: IMessage) {
    const { init, notify } = message;
    if (init) {
      this.events.init(init.grid, init.reports);
    }
    if (notify) {
      if (notify.grid_changed) {
        this.events.updateGrid(notify.grid_changed);
      }
      if (notify.report_added) {
        this.events.addReport(notify.report_added);
      }
      if (notify.report_removed) {
        this.events.deleteReport(notify.report_removed.id);
      }
    }
  }
}