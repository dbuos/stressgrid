import _ from 'lodash';
import ReconnectingWebSocket from 'reconnecting-websocket';

export interface IScriptError {
  description: string;
  line: number;
}

export interface IStats<T> {
  cpu_percent: T;
  network_rx_bytes_per_second: T;
  network_tx_bytes_per_second: T;
  active_device_number: T;
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
  maximums: IStats<number>;
  result: IResult;
  script_error?: IScriptError;
}

export interface IState {
  generator_count?: number;
  stats?: IStats<number[]> | null;
  run?: IRun | null;
  reports?: IReport[];
  last_script_error?: IScriptError | null;
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
  init?: IState;
  notify?: IState;
  start_run?: IRunPlan;
  remove_report?: IRemoveReport;
}

export interface IStressgridEvents {
  update(state: IState): void;
  connected(): void;
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
    this.ws.onopen = () => {
      this.events.connected();
    }
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

  public startRun(runPlan: IRunPlan) {
    this.send([{
      start_run: runPlan
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
    const { notify } = message;
    if (notify) {
      this.events.update(notify);
    }
  }
}