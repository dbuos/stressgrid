import * as _ from 'lodash';

import reportsStore from './stores/ReportsStore';
import runStore from './stores/RunStore';
import telemetryStore from './stores/TelemetryStore';

import ReconnectingWebSocket from 'reconnecting-websocket';

interface IScriptError {
  description: string;
  line: number;
}

interface ITelemetry {
  cpu: number[];
  network_rx: number[];
  network_tx: number[];
  active_count: number[];
  script_error?: IScriptError;
  generator_count: number[];
}

interface IRun {
  id: string;
  name: string;
  state: string;
  remaining_ms: number;
}

interface IResult {
  csv_url?: string;
  cw_url?: string;
}

interface IReport {
  id: string;
  name: string;
  max_cpu: number;
  max_network_rx: number;
  max_network_tx: number;
  max_script_error?: IScriptError;
  max_generator_count: number;
  result: IResult;
}

interface IInit {
  reports: IReport[];
  grid: IGrid;
}

interface IGrid {
  telemetry: ITelemetry;
  run: IRun | null;
}

interface INotify {
  grid_changed?: IGrid;
  report_added?: IReport;
  report_removed?: { id: string };
}

interface IBlock {
  script?: string;
  params?: object;
  size?: number;
}

interface IAddress {
  host: string;
  port?: number;
  protocol?: string;
}

interface IOpts {
  ramp_steps?: number;
  rampup_step_ms?: number;
  sustain_ms?: number;
  rampdown_step_ms?: number;
}

interface IRunPlan {
  name: string;
  blocks: IBlock[];
  addresses: IAddress[];
  opts: IOpts;
  script?: string;
}

interface IRemoveReport {
  id: string;
}

interface IMessage {
  init?: IInit;
  notify?: INotify;
  run_plan?: IRunPlan;
  remove_report?: IRemoveReport;
}

export class Ws {
  private ws: ReconnectingWebSocket;

  public connect(wsUrl: string) {
    this.ws = new ReconnectingWebSocket(wsUrl);
    this.ws.onmessage = (e) => {
      _.each(JSON.parse(e.data), (message: IMessage) => {
        this.handle(message);
      });
    }
  }

  public run(runPlan: IRunPlan) {
    this.send([{
      run_plan: runPlan
    }]);
  }

  public abortRun() {
    this.send(["abort_run"]);
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

  private updateGrid(g: IGrid) {
    const t = g.telemetry;
    telemetryStore.update(
      t.cpu,
      t.network_rx,
      t.network_tx,
      t.script_error ? t.script_error.description : null,
      t.active_count,
      t.generator_count);
    if (g.run) {
      const r = g.run;
      runStore.update(
        r.id,
        r.name,
        r.state,
        r.remaining_ms
      );
    }
    else {
      runStore.clear();
    }
  }

  private addReport(r: IReport) {
    reportsStore.addReport(r.id,
      {
        csvUrl: r.result.csv_url,
        cwUrl: r.result.cw_url,
        hasScriptErrors: !!r.max_script_error,
        maxCpu: r.max_cpu,
        maxNetworkRx: r.max_network_rx,
        maxNetworkTx: r.max_network_tx,
        name: r.name
      });
  }

  private handle(message: IMessage) {
    const { init, notify } = message;
    if (init) {
      telemetryStore.clear();
      runStore.clear();
      reportsStore.clear();

      this.updateGrid(init.grid);
      _.forEach(init.reports, r => this.addReport(r));
    }
    if (notify) {
      if (notify.grid_changed) {
        this.updateGrid(notify.grid_changed);
      }
      if (notify.report_added) {
        this.addReport(notify.report_added);
      }
      if (notify.report_removed) {
        reportsStore.deleteReport(notify.report_removed.id);
      }
    }
  }
}

const ws = new Ws();
export default ws;