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

const defaultJson = JSON.stringify({
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
}, null, 2);

interface IAppProps {
  telemetryStore?: TelemetryStore;
  runStore?: RunStore;
  reportsStore?: ReportsStore;
  ws?: Ws;
}

interface IAppState {
  error?: string;
  advanced: boolean;
}

@inject('telemetryStore')
@inject('runStore')
@inject('reportsStore')
@inject('ws')
@observer
class App extends React.Component<IAppProps, IAppState> {
  private jsonTextRef: React.RefObject<HTMLTextAreaElement> = React.createRef();

  private nameInputRef: React.RefObject<HTMLInputElement> = React.createRef();
  private desiredSizeInputRef: React.RefObject<HTMLInputElement> = React.createRef();

  private scriptTextRef: React.RefObject<HTMLTextAreaElement> = React.createRef();
  private paramsTextRef: React.RefObject<HTMLTextAreaElement> = React.createRef();

  private hostInputRef: React.RefObject<HTMLInputElement> = React.createRef();
  private portInputRef: React.RefObject<HTMLInputElement> = React.createRef();

  private rampupSecsInputRef: React.RefObject<HTMLInputElement> = React.createRef();
  private sustainSecsInputRef: React.RefObject<HTMLInputElement> = React.createRef();
  private rampdownSecsInputRef: React.RefObject<HTMLInputElement> = React.createRef();

  constructor(props: IAppProps) {
    super(props);
    this.state = { advanced: false };
  }

  public render() {
    const { telemetryStore, runStore, reportsStore } = this.props;
    return (
      <div className="fluid-container p-4">
        <div className="row">
          <div className="col-6">
            <h3>Plan</h3>
            <form className="bg-light rounded p-4">
              <div className="form-group form-check">
                <input type="checkbox" className="form-check-input" id="advanced" checked={this.state.advanced} onChange={this.changeAdvanced} />
                <label className="form-check-label" htmlFor="advanced">Advanced Mode</label>
              </div>
              {this.state.error && <div className="alert alert-warning" role="alert">
                {this.state.error}
              </div>}
              {telemetryStore && telemetryStore.recentScriptError && <div className="alert alert-danger" role="alert">
                {telemetryStore.recentScriptError}
              </div>}
              <fieldset>
                {this.state.advanced && <span>
                  <div className="form-group">
                    <label htmlFor="json">JSON</label>
                    <textarea className="form-control" id="json" rows={32} ref={this.jsonTextRef} defaultValue={defaultJson} />
                  </div>
                </span>}
                {!this.state.advanced && <span>
                  <div className="form-group">
                    <label htmlFor="name">Plan name</label>
                    <input className="form-control" id="name" type="text" ref={this.nameInputRef} defaultValue="10K" />
                  </div>
                  <div className="row">
                    <div className="col">
                      <div className="form-group">
                        <label htmlFor="desizedSize">Desired number of devices</label>
                        <input className="form-control" id="desizedSize" type="text" ref={this.desiredSizeInputRef} onChange={this.updateDesiredSize} defaultValue="10000" />
                      </div>
                    </div>
                    <div className="col">
                      <div className="form-group">
                        <label htmlFor="size">Effective number of devices</label>
                        <input className="form-control" id="size" type="text" value={_.defaultTo(telemetryStore ? telemetryStore.size : NaN, 0)} readOnly={true} />
                        <small id="passwordHelpBlock" className="form-text text-muted">Multiples of ramp step size: {telemetryStore ? telemetryStore.rampStepSize : NaN}</small>
                      </div>
                    </div>
                  </div>
                  <div className="form-group">
                    <label htmlFor="script">Script</label>
                    <textarea className="form-control" id="script" rows={6} ref={this.scriptTextRef} defaultValue={defaultScript} />
                  </div>
                  <div className="form-group">
                    <label htmlFor="params">Params</label>
                    <textarea className="form-control" id="params" rows={1} ref={this.paramsTextRef} defaultValue='{ }' />
                  </div>
                  <div className="row">
                    <div className="col">
                      <div className="form-group">
                        <label htmlFor="host">Target host(s)</label>
                        <input className="form-control" id="host" type="text" ref={this.hostInputRef} defaultValue="localhost" />
                        <small id="passwordHelpBlock" className="form-text text-muted">Comma separated</small>
                      </div>
                    </div>
                    <div className="col">
                      <div className="form-group">
                        <label htmlFor="port">Target port</label>
                        <input className="form-control" id="port" type="text" ref={this.portInputRef} defaultValue="5000" />
                      </div>
                    </div>
                  </div>
                  <div className="row">
                    <div className="col">
                      <div className="form-group">
                        <label htmlFor="rampupSecs">Rampup (seconds)</label>
                        <input className="form-control" id="rampupSecs" type="text" ref={this.rampupSecsInputRef} defaultValue="900" />
                      </div>
                    </div>
                    <div className="col">
                      <div className="form-group">
                        <label htmlFor="sustainSecs">Sustain (seconds)</label>
                        <input className="form-control" id="sustainSecs" type="text" ref={this.sustainSecsInputRef} defaultValue="900" />
                      </div>
                    </div>
                    <div className="col">
                      <div className="form-group">
                        <label htmlFor="rampdownSecs">Rampdown (seconds)</label>
                        <input className="form-control" id="rampdownSecs" type="text" ref={this.rampdownSecsInputRef} defaultValue="900" />
                      </div>
                    </div>
                  </div>
                </span>}
                <button className="btn btn-primary" onClick={this.runPlan}>Run</button>
              </fieldset>
            </form>
          </div>
          <div className="col-6">
            <h3>Summary</h3>
            {telemetryStore && <table className="table">
              <tbody>
                <tr>
                  <th scope="row" style={{ width: "50%" }}>Generators</th>
                  <td style={{ width: "20%" }}>{telemetryStore.generatorCount}</td>
                  <td style={{ width: "30%" }}>
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
                <tr>
                  <th scope="row">Max CPU Utilization</th>
                  <td>{Math.trunc(telemetryStore.cpu * 100)} %&nbsp;<FontAwesomeIcon style={{ color: telemetryStore.cpu > .8 ? "red" : "green" }} icon="cog" spin={_.defaultTo(telemetryStore.activeCount, 0) > 0} /></td>
                  <td>
                    <Sparklines data={_.reverse(_.clone(telemetryStore.recentCpu))} height={20}>
                      <SparklinesLine style={{ fill: "none" }} />
                      <SparklinesSpots />
                    </Sparklines>
                  </td>
                </tr>
                <tr>
                  <th scope="row">Total Network Receive</th>
                  <td>{filesize(telemetryStore.networkRx)}/sec</td>
                  <td>
                    <Sparklines data={_.reverse(_.clone(telemetryStore.recentNetworkRx))} height={20}>
                      <SparklinesLine style={{ fill: "none" }} />
                      <SparklinesSpots />
                    </Sparklines>
                  </td>
                </tr>
                <tr>
                  <th scope="row">Total Network Transmit</th>
                  <td>{filesize(telemetryStore.networkTx)}/sec</td>
                  <td>
                    <Sparklines data={_.reverse(_.clone(telemetryStore.recentNetworkTx))} height={20}>
                      <SparklinesLine style={{ fill: "none" }} />
                      <SparklinesSpots />
                    </Sparklines>
                  </td>
                </tr>
              </tbody>
            </table>}
            <h3>Runs</h3>
            {runStore && <table className="table">
              <thead>
                <tr>
                  <th scope="col" style={{ width: "30%" }}>ID</th>
                  <th scope="col" style={{ width: "20%" }}>Plan</th>
                  <th scope="col" style={{ width: "20%" }}>State</th>
                  <th scope="col" style={{ width: "15%" }}>Remaning</th>
                  <th scope="col" style={{ width: "15%" }}>Control</th>
                </tr>
              </thead>
              <tbody>
                {runStore.id &&
                  <tr key={runStore.id}>
                    <td><FontAwesomeIcon icon="spinner" spin={true} />&nbsp;{runStore.id}</td>
                    <td>{runStore.name}</td>
                    <td>{runStore.state}</td>
                    <td>{Math.trunc(_.defaultTo(runStore.remainingMs, 0) / 1000)} seconds</td>
                    <td><button className='btn btn-danger btn-sm' onClick={this.abortRun}>Abort</button></td>
                  </tr>
                }
              </tbody>
            </table>}
            <h3>Reports</h3>
            {reportsStore && <table className="table">
              <thead>
                <tr>
                  <th scope="col" style={{ width: "30%" }}>ID</th>
                  <th scope="col" style={{ width: "20%" }}>Plan</th>
                  <th scope="col" style={{ width: "20%" }}>Max CPU</th>
                  <th scope="col" style={{ width: "30%" }}>Results</th>
                </tr>
              </thead>
              <tbody>
                {_.reverse(_.map(reportsStore.reports, (report, id) => {
                  return <tr key={id}>
                    <td><FontAwesomeIcon style={{ color: (report.maxCpu > .8 || report.hasScriptErrors) ? "red" : "green" }} icon="flag" />&nbsp;{id}</td>
                    <td>{report.name}</td>
                    <td>{Math.trunc(report.maxCpu * 100)} %</td>
                    <td>{report.csvUrl ? <a href={report.csvUrl} className='btn btn-outline-info btn-sm mr-1' target='_blank'>CSV</a> : null}
                      {report.cwUrl ? <a href={report.cwUrl} className='btn btn-outline-info btn-sm mr-1' target='_blank'>CloudWatch</a> : null}
                      <button data-id={id} className='btn btn-outline-danger btn-sm mr-1' onClick={this.removeReport}>Clear</button></td>
                  </tr>
                }))}
              </tbody>
            </table>}
          </div>
        </div>
      </div>
    );
  }

  public componentDidMount() {
    this.updateDesiredSize();
  }

  private updateDesiredSize = () => {
    const desiredSizeInput = this.desiredSizeInputRef.current;
    if (desiredSizeInput && this.props.telemetryStore) {
      this.props.telemetryStore.desiredSize = parseInt(desiredSizeInput.value, 10);
    }
  }

  private changeAdvanced = () => {
    this.setState({
      advanced: !this.state.advanced
    });
  }

  private runPlan = (event: React.SyntheticEvent<HTMLButtonElement>) => {
    const { telemetryStore, ws } = this.props;
    if (this.state.advanced) {
      const jsonText = this.jsonTextRef.current;
      if (ws && telemetryStore && jsonText) {
        this.setState({ error: undefined });
        try {
          ws.run(JSON.parse(jsonText.value));
        }
        catch (e) {
          this.setState({ error: e.toString() });
        }
      }
    }
    else {
      const nameInput = this.nameInputRef.current;
      const scriptText = this.scriptTextRef.current;
      const paramsText = this.paramsTextRef.current;
      const hostInput = this.hostInputRef.current;
      const portInput = this.portInputRef.current;
      const rampupSecsInput = this.rampupSecsInputRef.current;
      const sustainSecsInput = this.sustainSecsInputRef.current;
      const rampdownSecsInput = this.rampdownSecsInputRef.current;

      if (ws && telemetryStore && nameInput && hostInput && portInput && scriptText && paramsText && rampupSecsInput && sustainSecsInput && rampdownSecsInput) {
        this.setState({ error: undefined });
        try {
          const name = nameInput.value;
          const port = parseInt(portInput.value, 10);
          const size = telemetryStore.size;
          const rampSteps = telemetryStore.rampSteps;
          const rampdownStepMs = (parseInt(rampdownSecsInput.value, 10) * 1000) / rampSteps;
          const rampupStepMs = (parseInt(rampupSecsInput.value, 10) * 1000) / rampSteps;
          const sustainMs = (parseInt(sustainSecsInput.value, 10) * 1000);
          if (_.isEmpty(name)) { throw new Error('Name is invalid'); }
          if (isNaN(port) || port <= 0) { throw new Error('Port is invalid'); }
          if (isNaN(size) || size <= 0) { throw new Error('Effective size is invalid'); }
          if (isNaN(rampSteps) || rampSteps <= 0) { throw new Error('Ramp steps is invalid'); }
          if (isNaN(rampdownStepMs) || rampdownStepMs <= 0) { throw new Error('Rampdown duration is invalid'); }
          if (isNaN(rampupStepMs) || rampupStepMs <= 0) { throw new Error('Ramup duration is invalid'); }
          if (isNaN(sustainMs) || sustainMs <= 0) { throw new Error('Sustain duration is invalid'); }
          ws.run({
            addresses: _.map(_.split(hostInput.value, ","), host => {
              return {
                host: _.trim(host),
                port
              };
            }),
            blocks: [{
              params: JSON.parse(paramsText.value),
              size
            }],
            name,
            opts: {
              ramp_steps: rampSteps,
              rampdown_step_ms: rampdownStepMs,
              rampup_step_ms: rampupStepMs,
              sustain_ms: sustainMs
            },
            script: scriptText.value
          });
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
