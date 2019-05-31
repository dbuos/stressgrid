#! /usr/bin/env node

import * as _ from 'lodash';

import * as program from 'commander';
import ReconnectingWebSocket from 'reconnecting-websocket';
import * as WS from 'ws';
import * as fs from 'fs';

interface IScriptError {
  description: string;
  line: number;
}

interface ITelemetry {
  cpu: number[];
  network_rx: number[];
  network_tx: number[];
  active_count: number[];
  last_errors?: Map<string, number[]>;
  last_script_error?: IScriptError;
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
  errors?: Map<string, number[]>;
  script_error?: IScriptError;
  max_cpu: number;
  max_network_rx: number;
  max_network_tx: number;
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

interface IStressgridEvents {
  init(grid: IGrid, reports: IReport[]): void;
  updateGrid(grid: IGrid): void;
}

export class Stressgrid {
  private ws: ReconnectingWebSocket;
  private events: IStressgridEvents;

  constructor(events: IStressgridEvents) {
    this.events = events;
  }

  public connect(wsUrl: string) {
    this.ws = new ReconnectingWebSocket(wsUrl, [], {
      WebSocket: WS
    });
    this.ws.onmessage = (e) => {
      _.each(JSON.parse(e.data), (message: IMessage) => {
        this.handle(message);
      });
    }
  }

  public disconnect() {
    this.ws.close();
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
        //this.events.addReport(notify.report_added);
      }
      if (notify.report_removed) {
        //this.events.deleteReport(notify.report_removed.id);
      }
    }
  }
}

program
  .option('-c, --coordinator-host <string>', 'coordinator host (localhost)')
  .version('0.1.0');

program
  .command('run <name> <script>')
  .description('run plan')
  .option('-t, --target-hosts <string>', 'target hosts, comma separated (localhost)')
  .option('-s, --size <number>', 'number of devices (10000)', parseInt)
  .option('--target-port <number>', 'target port (5000)', parseInt)
  .option('--target-protocol <string>', 'target protocol http|https|tcp|udp (http)')
  .option('--script-params <json>', 'script parameters ({})')
  .option('--rampup <number>', 'rampup seconds (900)', parseInt)
  .option('--sustain <number>', 'sustain seconds (900)', parseInt)
  .option('--rampdown <number>', 'rampdown seconds (900)', parseInt)
  .action((name, script, options) => {
    if (!fs.existsSync(script)) {
      console.error('script file must exist');
      return;
    }
    console.log('connecting...')
    const sg = new Stressgrid({
      init: (grid, reports) => {
        if (!grid.telemetry.generator_count[0]) {
          console.error('must have at least one generator');
          sg.disconnect();
          return;
        }
        if (grid.run) {
          console.error('already running, please stop current run');
          sg.disconnect();
          return;
        }
        console.log('running...')
        sg.run({
          addresses: _.map(_.split(_.defaultTo(options.targetHosts, 'localhost'), ','), host => {
            return {
              host: _.trim(host),
              port: _.defaultTo(options.targetPort, 5000),
              protocol: _.defaultTo(options.targetProtocol, 'http')
            };
          }),
          blocks: [{
            params: JSON.parse(_.defaultTo(options.scriptParams, '{}')),
            size: _.defaultTo(options.size, 10000)
          }],
          name,
          opts: {
            ramp_steps: 1000,
            rampdown_step_ms: _.defaultTo(options.rampdown, 900),
            rampup_step_ms: _.defaultTo(options.rampup, 900),
            sustain_ms: _.defaultTo(options.sustain, 900) * 1000
          },
          script: fs.readFileSync(script).toString()
        });
      },
      updateGrid: (grid) => {
        if (!grid.run || grid.run.name !== name) {
          sg.disconnect();
        }
      }
    });
    sg.connect('ws://' + _.defaultTo(program.coordinatorHost, 'localhost') + ':8000/ws');
  });

program.parse(process.argv);

if (!process.argv.slice(2).length) {
  program.outputHelp();
}