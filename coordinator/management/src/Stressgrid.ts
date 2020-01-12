import _ from 'lodash';
import ReconnectingWebSocket from 'reconnecting-websocket';

export interface ScriptError {
  description: string;
  line: number;
}

export type Statistic = string

export type Statistics<T> = Record<Statistic, T>;

export interface Run {
  id: string;
  name: string;
  state: string;
  remaining_ms: number;
}

export interface Result {
  csv_url?: string;
  cw_url?: string;
}

export interface Report {
  id: string;
  name: string;
  maximums: Statistics<number>;
  result: Result;
  script_error?: ScriptError;
}

export interface State {
  generator_count?: number;
  stats?: Statistics<Array<number | null>> | null;
  run?: Run | null;
  reports?: Report[];
  last_script_error?: ScriptError | null;
}

export interface Block {
  script: string;
  size?: number;
  params?: object;
}

export type Protocol = "http10" | "http10s" | "http" | "https" | "http2" | "http2s" | "tcp" | "udp";

export interface Address {
  host: string;
  port?: number;
  protocol?: Protocol;
}

export interface Opts {
  ramp_steps?: number;
  rampup_step_ms?: number;
  sustain_ms?: number;
  rampdown_step_ms?: number;
}

export interface RunPlan {
  name: string;
  addresses: Address[];
  blocks: Block[];
  opts: Opts;
}

export interface RemoveReport {
  id: string;
}

export type Message = { notify: State; } | { start_run: RunPlan; } | { remove_report: RemoveReport; }

export interface StressgridEvents {
  update(state: State): void;
  connected(): void;
  disconnected(): void;
}

export class Stressgrid {
  private ws: ReconnectingWebSocket;
  private events: StressgridEvents;

  constructor(events: StressgridEvents, wsUrl: string, WebSocket?: any) {
    this.events = events;
    this.ws = new ReconnectingWebSocket(wsUrl, [], {
      WebSocket
    });
    this.ws.onopen = () => {
      this.events.connected();
    }
    this.ws.onmessage = (e) => {
      _.each(JSON.parse(e.data), (message: Message) => {
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

  public startRun(runPlan: RunPlan) {
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

  private send(messages: Array<Message | string>) {
    this.ws.send(JSON.stringify(messages));
  }

  private handle(message: Message) {
    if ("notify" in message) {
      this.events.update(message.notify);
    }
  }
}