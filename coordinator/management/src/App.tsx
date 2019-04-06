import * as filesize from 'filesize';
import * as _ from 'lodash';
import { inject, observer } from 'mobx-react';
import * as React from 'react';
import { Sparklines, SparklinesLine, SparklinesSpots } from 'react-sparklines';

import { FontAwesomeIcon } from '@fortawesome/react-fontawesome'

import { ReportsStore } from './stores/ReportsStore'
import { RunStore } from './stores/RunStore'
import { TelemetryStore } from './stores/TelemetryStore'
import { Ws } from './Ws';

const defaultScript = `0..100 |> Enum.each(fn _ ->
  get("/")
  delay(900, 0.1)
end)`;

const defaultPlan = {
  addresses: [{
    host: 'localhost',
    port: 5000
  }],
  blocks: [{
    params: {},
    size: 10000
  }],
  name: '10k',
  opts: {
    ramp_steps: 1000,
    rampdown_step_ms: 900,
    rampup_step_ms: 900,
    sustain_ms: 900000
  },
  script: defaultScript
};

interface IAppProps {
  telemetryStore?: TelemetryStore;
  runStore?: RunStore;
  reportsStore?: ReportsStore;
  ws?: Ws;
}

interface IAppState {
  error?: string;
  planModal: boolean;
  advanced: boolean;
  json: string;
  name: string;
  script: string;
  params: string;
  host: string;
  port: number;
  rampupSecs: number;
  sustainSecs: number;
  rampdownSecs: number;
}

@inject('telemetryStore')
@inject('runStore')
@inject('reportsStore')
@inject('ws')
@observer
class App extends React.Component<IAppProps, IAppState> {
  constructor(props: IAppProps) {
    super(props);
    this.state = {
      advanced: false,
      host: defaultPlan.addresses[0].host,
      json: JSON.stringify(defaultPlan, null, 2),
      name: defaultPlan.name,
      params: JSON.stringify(defaultPlan.blocks[0].params),
      planModal: false,
      port: defaultPlan.addresses[0].port,
      rampdownSecs: Math.trunc((defaultPlan.opts.ramp_steps * defaultPlan.opts.rampdown_step_ms) / 1000),
      rampupSecs: Math.trunc((defaultPlan.opts.ramp_steps * defaultPlan.opts.rampup_step_ms) / 1000),
      script: defaultScript,
      sustainSecs: Math.trunc(defaultPlan.opts.sustain_ms / 1000)
    };
  }

  public render() {
    const { telemetryStore, runStore, reportsStore } = this.props;
    return (
      <div className="container p-4">
        {this.state.planModal && <span>
          <h3>Plan</h3>
          <form>
            <div className="form-group form-check">
              <input type="checkbox" className="form-check-input" id="advanced" checked={this.state.advanced} onChange={this.changeAdvanced} />
              <label className="form-check-label" htmlFor="advanced">Advanced Mode</label>
            </div>
            {this.state.error && <div className="alert alert-warning" role="alert">
              {this.state.error}
            </div>}
            <fieldset>
              {this.state.advanced && <span>
                <div className="form-group">
                  <label htmlFor="json">JSON</label>
                  <textarea className="form-control" id="json" rows={24} value={this.state.json} onChange={this.updateJson} />
                </div>
              </span>}
              {!this.state.advanced && <span>
                <div className="form-group">
                  <label htmlFor="name">Plan name</label>
                  <input className="form-control" id="name" type="text" value={this.state.name} onChange={this.updateName} />
                </div>
                <div className="row">
                  <div className="col">
                    <div className="form-group">
                      <label htmlFor="desizedSize">Desired number of devices</label>
                      {telemetryStore && <input className="form-control" id="desizedSize" type="text" value={telemetryStore.desiredSize} onChange={this.updateDesiredSize} />}
                    </div>
                  </div>
                  <div className="col">
                    <div className="form-group">
                      <label htmlFor="size">Effective number of devices</label>
                      <input className="form-control" id="size" type="text" value={_.defaultTo(telemetryStore ? telemetryStore.size : NaN, 0)} readOnly={true} />
                      <small className="form-text text-muted">Multiples of ramp step size: {telemetryStore ? telemetryStore.rampStepSize : NaN}</small>
                    </div>
                  </div>
                </div>
                <div className="form-group">
                  <label htmlFor="script">Script</label>
                  <textarea className="form-control" id="script" rows={6} value={this.state.script} onChange={this.updateScript} />
                </div>
                <div className="form-group">
                  <label htmlFor="params">Params</label>
                  <textarea className="form-control" id="params" rows={1} value={this.state.params} onChange={this.updateParams} />
                </div>
                <div className="row">
                  <div className="col">
                    <div className="form-group">
                      <label htmlFor="host">Target host(s)</label>
                      <input className="form-control" id="host" type="text" value={this.state.host} onChange={this.updateHost} />
                      <small className="form-text text-muted">Comma separated</small>
                    </div>
                  </div>
                  <div className="col">
                    <div className="form-group">
                      <label htmlFor="port">Target port</label>
                      <input className="form-control" id="port" type="text" value={this.state.port} onChange={this.updatePort} />
                    </div>
                  </div>
                </div>
                <div className="row">
                  <div className="col">
                    <div className="form-group">
                      <label htmlFor="rampupSecs">Rampup (seconds)</label>
                      <input className="form-control" id="rampupSecs" type="text" value={this.state.rampupSecs} onChange={this.updateRampupSecs} />
                    </div>
                  </div>
                  <div className="col">
                    <div className="form-group">
                      <label htmlFor="sustainSecs">Sustain (seconds)</label>
                      <input className="form-control" id="sustainSecs" type="text" value={this.state.sustainSecs} onChange={this.updateSustainSecs} />
                    </div>
                  </div>
                  <div className="col">
                    <div className="form-group">
                      <label htmlFor="rampdownSecs">Rampdown (seconds)</label>
                      <input className="form-control" id="rampdownSecs" type="text" value={this.state.rampdownSecs} onChange={this.updateRampdownSecs} />
                    </div>
                  </div>
                </div>
              </span>}
              <button className="btn btn-primary" onClick={this.runPlan}>Run</button>
              &nbsp;
              <button className="btn" onClick={this.cancelPlan}>Cancel</button>
            </fieldset>
          </form></span>}
        {telemetryStore && runStore && !this.state.planModal && <span>
          <h3>Stressgrid</h3>
          <table className="table">
            <tbody>
              <tr>
                <th scope="row" style={{ width: "30%" }}>Current Run (Plan)</th>
                <td style={{ width: "40%" }}>
                  {runStore.id &&
                    <span>{runStore.id}&nbsp;({runStore.name})</span>
                  }
                </td>
                <td style={{ width: "30%" }}>
                  {runStore.id ?
                    <button className='btn btn-danger btn-sm' onClick={this.abortRun}>Abort</button> :
                    <button className="btn btn-primary btn-sm" onClick={this.showPlanModal}>Start</button>
                  }
                </td>
              </tr>
              <tr>
                <th scope="row">State</th>
                <td>
                  {runStore.id ?
                    <b>{runStore.state}</b> :
                    <b>idle</b>
                  }
                </td>
                <td>
                  {runStore.id &&
                    <span>{Math.trunc(_.defaultTo(runStore.remainingMs, 0) / 1000)} seconds remaining</span>
                  }
                </td>
              </tr>
              <tr>
                <th scope="row">Generators</th>
                <td>{telemetryStore.generatorCount}</td>
                <td>
                  <Sparklines data={_.reverse(_.clone(telemetryStore.recentGeneratorCount))} height={20}>
                    <SparklinesLine style={{ fill: "none" }} />
                    <SparklinesSpots />
                  </Sparklines>
                </td>
              </tr>
              <tr>
                <th scope="row">Active Devices</th>
                <td>{telemetryStore.activeCount}</td>
                <td>
                  <Sparklines data={_.reverse(_.clone(telemetryStore.recentActiveCount))} height={20}>
                    <SparklinesLine style={{ fill: "none" }} />
                    <SparklinesSpots />
                  </Sparklines>
                </td>
              </tr>
              {telemetryStore.lastScriptError && <tr>
                <th scope="row">Script Error</th>
                <td colSpan={2}>
                  <small>{telemetryStore.lastScriptError}</small>&nbsp;
                  <FontAwesomeIcon style={{ color: "red" }} icon="flag" />
                </td>
              </tr>}
              {telemetryStore.lastErrors && _.map(_.toPairs(telemetryStore.lastErrors), pair => {
                const recentCounts = pair[1];
                const type = pair[0];
                return <tr>
                  <th scope="row"><samp>{type}</samp> Error Count</th>
                  <td>
                    <span>{recentCounts[0]}</span>&nbsp;
                    <FontAwesomeIcon style={{ color: "red" }} icon="flag" />
                  </td>
                  <td>
                    <Sparklines data={_.reverse(_.clone(recentCounts))} height={20}>
                      <SparklinesLine style={{ fill: "none" }} />
                      <SparklinesSpots />
                    </Sparklines>
                  </td>
                </tr>;
              })}
              <tr>
                <th scope="row">CPU Utilization</th>
                <td>
                  <span>{Math.trunc(telemetryStore.cpu * 100)} %</span>&nbsp;
                  <FontAwesomeIcon style={{ color: telemetryStore.cpu > .8 ? "red" : "green" }} icon="cog" spin={_.defaultTo(telemetryStore.activeCount, 0) > 0} />
                </td>
                <td>
                  <Sparklines data={_.reverse(_.clone(telemetryStore.recentCpu))} height={20}>
                    <SparklinesLine style={{ fill: "none" }} />
                    <SparklinesSpots />
                  </Sparklines>
                </td>
              </tr>
              <tr>
                <th scope="row">Network Receive</th>
                <td>{filesize(telemetryStore.networkRx)}/sec</td>
                <td>
                  <Sparklines data={_.reverse(_.clone(telemetryStore.recentNetworkRx))} height={20}>
                    <SparklinesLine style={{ fill: "none" }} />
                    <SparklinesSpots />
                  </Sparklines>
                </td>
              </tr>
              <tr>
                <th scope="row">Network Transmit</th>
                <td>{filesize(telemetryStore.networkTx)}/sec</td>
                <td>
                  <Sparklines data={_.reverse(_.clone(telemetryStore.recentNetworkTx))} height={20}>
                    <SparklinesLine style={{ fill: "none" }} />
                    <SparklinesSpots />
                  </Sparklines>
                </td>
              </tr>
            </tbody>
          </table>
          <h3>Reports</h3>
          {reportsStore && <table className="table">
            <thead>
              <tr>
                <th scope="col" style={{ width: "30%" }}>Run</th>
                <th scope="col" style={{ width: "20%" }}>Plan</th>
                <th scope="col" style={{ width: "20%" }}>Max CPU</th>
                <th scope="col" style={{ width: "30%" }}>Results</th>
              </tr>
            </thead>
            <tbody>
              {_.reverse(_.map(reportsStore.reports, (report, id) => {
                return <tr key={id}>
                  <td>
                    <FontAwesomeIcon style={{ color: (report.maxCpu > .8) ? "red" : "green" }} icon="cog" />&nbsp;
                    <FontAwesomeIcon style={{ color: (report.hasNonScriptErrors || report.hasScriptErrors) ? "red" : "green" }} icon="flag" />&nbsp;
                    <span>{id}</span>
                  </td>
                  <td>{report.name}</td>
                  <td>{Math.trunc(report.maxCpu * 100)} %</td>
                  <td>{report.csvUrl ? <a href={report.csvUrl} className='btn btn-outline-info btn-sm mr-1' target='_blank'>CSV</a> : null}
                    {report.cwUrl ? <a href={report.cwUrl} className='btn btn-outline-info btn-sm mr-1' target='_blank'>CloudWatch</a> : null}
                    <button data-id={id} className='btn btn-outline-danger btn-sm mr-1' onClick={this.removeReport}>Clear</button></td>
                </tr>
              }))}
            </tbody>
          </table>}
        </span>}
      </div>
    );
  }

  private parseInt(s: string) {
    const v = parseInt(s, 10);
    return isNaN(v) ? 0 : v;
  }

  private updateJson = (event: React.SyntheticEvent<HTMLTextAreaElement>) => {
    this.setState({ json: event.currentTarget.value });
  }

  private updateName = (event: React.SyntheticEvent<HTMLInputElement>) => {
    this.setState({ name: event.currentTarget.value });
  }

  private updateDesiredSize = (event: React.SyntheticEvent<HTMLInputElement>) => {
    if (this.props.telemetryStore) {
      this.props.telemetryStore.desiredSize = this.parseInt(event.currentTarget.value);
    }
  }

  private updateScript = (event: React.SyntheticEvent<HTMLTextAreaElement>) => {
    this.setState({ script: event.currentTarget.value });
  }

  private updateParams = (event: React.SyntheticEvent<HTMLTextAreaElement>) => {
    this.setState({ params: event.currentTarget.value });
  }

  private updateHost = (event: React.SyntheticEvent<HTMLInputElement>) => {
    this.setState({ host: event.currentTarget.value });
  }

  private updatePort = (event: React.SyntheticEvent<HTMLInputElement>) => {
    this.setState({ port: this.parseInt(event.currentTarget.value) });
  }

  private updateRampupSecs = (event: React.SyntheticEvent<HTMLInputElement>) => {
    this.setState({ rampupSecs: this.parseInt(event.currentTarget.value) });
  }

  private updateSustainSecs = (event: React.SyntheticEvent<HTMLInputElement>) => {
    this.setState({ sustainSecs: this.parseInt(event.currentTarget.value) });
  }

  private updateRampdownSecs = (event: React.SyntheticEvent<HTMLInputElement>) => {
    this.setState({ rampdownSecs: this.parseInt(event.currentTarget.value) });
  }

  private changeAdvanced = () => {
    this.setState({
      advanced: !this.state.advanced
    });
  }

  private showPlanModal = () => {
    this.setState({ error: undefined, planModal: true });
  }

  private hidePlanModal = () => {
    this.setState({ planModal: false });
  }

  private cancelPlan = (event: React.SyntheticEvent<HTMLButtonElement>) => {
    this.hidePlanModal();
    event.preventDefault();
  }

  private runPlan = (event: React.SyntheticEvent<HTMLButtonElement>) => {
    const { telemetryStore, ws } = this.props;
    if (ws && telemetryStore) {
      if (this.state.advanced) {
        const json = this.state.json;
        try {
          ws.run(JSON.parse(json));
        }
        catch (e) {
          this.setState({ error: e.toString() });
        }
      }
      else {
        try {
          const name = this.state.name;
          const port = this.state.port;
          const size = telemetryStore.size;
          const rampSteps = telemetryStore.rampSteps;
          const rampdownStepMs = (this.state.rampdownSecs * 1000) / rampSteps;
          const rampupStepMs = (this.state.rampupSecs * 1000) / rampSteps;
          const sustainMs = (this.state.sustainSecs * 1000);
          if (_.isEmpty(name)) { throw new Error('Name is invalid'); }
          if (port <= 0) { throw new Error('Port is invalid'); }
          if (size <= 0) { throw new Error('Effective size is invalid'); }
          if (rampSteps <= 0) { throw new Error('Ramp steps is invalid'); }
          if (rampdownStepMs <= 0) { throw new Error('Rampdown duration is invalid'); }
          if (rampupStepMs <= 0) { throw new Error('Ramup duration is invalid'); }
          if (sustainMs <= 0) { throw new Error('Sustain duration is invalid'); }
          ws.run({
            addresses: _.map(_.split(this.state.host, ","), host => {
              return {
                host: _.trim(host),
                port
              };
            }),
            blocks: [{
              params: JSON.parse(this.state.params),
              size
            }],
            name,
            opts: {
              ramp_steps: rampSteps,
              rampdown_step_ms: rampdownStepMs,
              rampup_step_ms: rampupStepMs,
              sustain_ms: sustainMs
            },
            script: this.state.script
          });
          this.hidePlanModal();
        }
        catch (e) {
          this.setState({ error: e.toString() });
        }
      }
    }
    event.preventDefault();
  }

  private abortRun = (event: React.SyntheticEvent<HTMLButtonElement>) => {
    const { ws } = this.props;
    if (ws) {
      ws.abortRun();
    }
  }

  private removeReport = (event: React.SyntheticEvent<HTMLButtonElement>) => {
    const { ws } = this.props;
    const id = event.currentTarget.dataset.id
    if (ws && id) {
      ws.removeReport(id);
    }
  }
}

export default App;
