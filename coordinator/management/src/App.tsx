import * as filesize from 'filesize';
import * as _ from 'lodash';
import { inject, observer } from 'mobx-react';
import * as React from 'react';
import CopyToClipboard from 'react-copy-to-clipboard';
import { Sparklines, SparklinesLine, SparklinesSpots } from 'react-sparklines';

import { FontAwesomeIcon } from '@fortawesome/react-fontawesome'

import { StateStore, } from './stores/StateStore'
import { Stressgrid } from './Stressgrid';

const defaultScript = `0..100 |> Enum.each(fn _ ->
  get("/")
  delay(900, 0.1)
end)`;

const defaultPlan = {
  addresses: [{
    host: 'localhost',
    port: 5000,
    protocol: 'http'
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
  stateStore?: StateStore;
  sg?: Stressgrid;
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
  protocol: string;
  rampupSecs: number;
  sustainSecs: number;
  rampdownSecs: number;
}

const errorCountRegex = /.*_error_?(count|per_second)$/;

const bytesPerSecondRegex = /(.*)_bytes_per_second$/;
const perSecondRegex = /(.*)_per_second$/;
const percentRegex = /(.*)_percent$/;
const microsecondRegex = /(.*)_us$/;
const countRegex = /(.*)_count$/;
const numberRegex = /(.*)_number$/;

const redCpuPercent = 80;

function statsRedCpuPercent(values: any[]): boolean {
  const value = _.first(values);
  return _.isNumber(value) && value > redCpuPercent;
}

function statsError(key: string) {
  return errorCountRegex.test(key);
}

function hasErrors(keys: string[]) {
  return _.some(keys, key => errorCountRegex.test(key));
}

function statsName(key: string) {
  let r: RegExpExecArray | null;
  r = bytesPerSecondRegex.exec(key);
  if (r !== null) {
    return _.startCase(r[1]) + ' (throughput)';
  }
  r = perSecondRegex.exec(key)
  if (r !== null) {
    return _.startCase(r[1]) + ' (rate)';
  }
  r = percentRegex.exec(key)
  if (r !== null) {
    return _.startCase(r[1]) + ' (load)';
  }
  r = r = microsecondRegex.exec(key)
  if (r !== null) {
    return _.startCase(r[1]) + ' (time)';
  }
  r = countRegex.exec(key);
  if (r !== null) {
    return _.startCase(r[1]) + ' (count)';
  }
  r = numberRegex.exec(key)
  if (r !== null) {
    return _.startCase(r[1]) + ' (number)';
  }

  return _.startCase(key);
}

function statsValue(key: string, values: any[]): string {
  const value = _.first(values);
  if (_.isNumber(value) && bytesPerSecondRegex.test(key)) {
    return filesize(value) + '/sec';
  }
  if (_.isNumber(value) && perSecondRegex.test(key)) {
    return value.toString() + ' /sec';
  }
  if (_.isNumber(value) && percentRegex.test(key)) {
    return Math.trunc(value).toString() + ' %';
  }
  if (_.isNumber(value) && microsecondRegex.test(key)) {
    if (value >= 1000000) {
      return Math.trunc(value / 1000000).toString() + ' seconds';
    }
    if (value >= 1000) {
      return Math.trunc(value / 1000).toString() + ' milliseconds';
    }
    return value.toString() + ' microseconds';
  }
  if (_.isNumber(value) && countRegex.test(key)) {
    return value.toString();
  }
  if (_.isNumber(value) && numberRegex.test(key)) {
    return value.toString();
  }
  if (value === null) {
    return '-';
  }

  return value.toString();
}

function statsSparkline(values: any[]): number[] {
  return _.reject(_.reverse(_.clone(values)), v => v === null);
}

@inject('stateStore')
@inject('sg')
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
      protocol: defaultPlan.addresses[0].protocol,
      rampdownSecs: Math.trunc((defaultPlan.opts.ramp_steps * defaultPlan.opts.rampdown_step_ms) / 1000),
      rampupSecs: Math.trunc((defaultPlan.opts.ramp_steps * defaultPlan.opts.rampup_step_ms) / 1000),
      script: defaultScript,
      sustainSecs: Math.trunc(defaultPlan.opts.sustain_ms / 1000)
    };
  }

  public render() {
    const { stateStore } = this.props;
    return (
      <div className="container-fluid p-4">
        {this.state.planModal && <div className="row">
          <div className="col">
            <h3>Start</h3>
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
                  <div className="row">
                    <div className="col">
                      <div className="form-group">
                        <label htmlFor="name">Run name</label>
                        <input className="form-control" id="name" type="text" value={this.state.name} onChange={this.updateName} />
                      </div>
                    </div>
                    <div className="col">
                      <div className="form-group">
                        <label htmlFor="desizedSize">Desired number of devices</label>
                        {stateStore && <input className="form-control" id="desizedSize" type="text" value={stateStore.desiredSize} onChange={this.updateDesiredSize} />}
                      </div>
                    </div>
                    <div className="col">
                      <div className="form-group">
                        <label htmlFor="size">Effective number of devices</label>
                        <input className="form-control" id="size" type="text" value={_.defaultTo(stateStore ? stateStore.size : NaN, 0)} readOnly={true} />
                        <small className="form-text text-muted">Multiples of ramp step size: {stateStore ? stateStore.rampStepSize : NaN}</small>
                      </div>
                    </div>
                  </div>
                  <div className="row">
                    <div className="col">
                      <div className="form-group">
                        <label htmlFor="protocol">Protocol</label>
                        <select className="form-control" id="protocol" value={this.state.protocol} onChange={this.updateProtocol}>
                          <option value="http10">HTTP 1.0</option>
                          <option value="http10s">HTTP 1.0 over TLS</option>
                          <option value="http">HTTP 1.1</option>
                          <option value="https">HTTP 1.1 over TLS</option>
                          <option value="http2">HTTP 2</option>
                          <option value="http2s">HTTP 2 over TLS</option>
                          <option value="tcp">TCP</option>
                          <option value="udp">UDP</option>
                        </select>
                      </div>
                    </div>
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
                  <div className="row">
                    <div className="col">
                      <div className="form-group">
                        <label htmlFor="script">Script</label>
                        <textarea className="form-control" id="script" rows={6} value={this.state.script} onChange={this.updateScript} />
                        <small className="form-text text-muted">Elixir</small>
                      </div>
                    </div>
                    <div className="col">
                      <div className="form-group">
                        <label htmlFor="params">Params</label>
                        <textarea className="form-control" id="params" rows={6} value={this.state.params} onChange={this.updateParams} />
                        <small className="form-text text-muted">JSON</small>
                      </div>
                    </div>
                  </div>
                </span>}
                <button className="btn btn-primary" onClick={this.runPlan}>Start</button>
                &nbsp;
              <button className="btn" onClick={this.cancelPlan}>Cancel</button>
              </fieldset>
            </form>
          </div>
        </div>}
        {stateStore && !this.state.planModal && <div className="row">
          <div className="col">
            <h3>Stressgrid</h3>
            <table className="table">
              <tbody>
                <tr>
                  <th scope="row" style={{ width: "30%" }}>Current Run</th>
                  <td style={{ width: "40%" }}>
                    {stateStore.state.run &&
                      <span>{stateStore.state.run.id}</span>
                    }
                  </td>
                  <td style={{ width: "30%" }}>
                    {stateStore.state.run ?
                      <button className='btn btn-danger btn-sm' onClick={this.abortRun}>Abort</button> :
                      <button className="btn btn-primary btn-sm" onClick={this.showPlanModal}>Start</button>
                    }
                  </td>
                </tr>
                <tr>
                  <th scope="row">State</th>
                  <td>
                    {stateStore.state.run ?
                      <b>{stateStore.state.run.state}</b> :
                      <b>idle</b>
                    }
                  </td>
                  <td>
                    {stateStore.state.run &&
                      <span>{Math.trunc(_.defaultTo(stateStore.state.run.remaining_ms, 0) / 1000)} seconds remaining</span>
                    }
                  </td>
                </tr>
                <tr>
                  <th scope="row">Generators</th>
                  <td>{stateStore.generatorCount}</td>
                  <td />
                </tr>
                {stateStore.state.last_script_error && <tr>
                  <th scope="row">Script Error</th>
                  <td colSpan={2}>
                    <small>{stateStore.state.last_script_error.description}</small>&nbsp;
                  <FontAwesomeIcon style={{ color: "red" }} icon="flag" />
                  </td>
                </tr>}
                {stateStore.state.stats && _.map(stateStore.state.stats, (values, key) => {
                  return <tr>
                    <th scope="row">{statsName(key)}</th>
                    <td>{statsValue(key, values)}
                      {key === "cpu_percent" ? <span>&nbsp;<FontAwesomeIcon style={{ color: statsRedCpuPercent(values) ? "red" : "green" }} icon="cog" spin={true} /></span> : null}
                      {statsError(key) ? <span>&nbsp;<FontAwesomeIcon style={{ color: "red" }} icon="flag" /></span> : null}
                    </td>
                    <td>
                      <Sparklines data={statsSparkline(values)} height={20}>
                        <SparklinesLine style={{ fill: "none" }} />
                        <SparklinesSpots />
                      </Sparklines>
                    </td>
                  </tr>
                })}
              </tbody>
            </table>
          </div>
          <div className="col">
            <h3>Reports</h3>
            {stateStore.state.reports && <table className="table">
              <thead>
                <tr>
                  <th scope="col" style={{ width: "50%" }}>Run</th>
                  <th scope="col" style={{ width: "10%" }}>Errors</th>
                  <th scope="col" style={{ width: "15%" }}>Max CPU</th>
                  <th scope="col" style={{ width: "25%" }}>Results</th>
                </tr>
              </thead>
              <tbody>
                {_.map(stateStore.state.reports, report => {
                  return <tr key={report.id}>
                    <td>
                      <span>{report.id}</span>&nbsp;
                      <CopyToClipboard text={report.id}>
                        <span title="Click to copy to clipboard"><FontAwesomeIcon icon="copy" /></span>
                      </CopyToClipboard>
                    </td>
                    <td><FontAwesomeIcon style={{ color: (report.script_error || hasErrors(_.keys(report.maximums))) ? "red" : "green" }} icon="flag" /></td>
                    <td>{report.maximums.cpu_percent}&nbsp;%&nbsp;<FontAwesomeIcon style={{ color: report.maximums.cpu_percent > redCpuPercent ? "red" : "green" }} icon="cog" /></td>
                    <td>{report.result.csv_url ? <a href={report.result.csv_url} className='btn btn-outline-info btn-sm mr-1' target='_blank'>CSV</a> : null}
                      {report.result.cw_url ? <a href={report.result.cw_url} className='btn btn-outline-info btn-sm mr-1' target='_blank'>CloudWatch</a> : null}
                      <button data-id={report.id} className='btn btn-outline-danger btn-sm mr-1' onClick={this.removeReport}>Clear</button></td>
                  </tr>
                })}
              </tbody>
            </table>}
          </div>
        </div>}
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
    if (this.props.stateStore) {
      this.props.stateStore.desiredSize = this.parseInt(event.currentTarget.value);
    }
  }

  private updateScript = (event: React.SyntheticEvent<HTMLTextAreaElement>) => {
    this.setState({ script: event.currentTarget.value });
  }

  private updateParams = (event: React.SyntheticEvent<HTMLTextAreaElement>) => {
    this.setState({ params: event.currentTarget.value });
  }

  private updateProtocol = (event: React.SyntheticEvent<HTMLSelectElement>) => {
    this.setState({ protocol: event.currentTarget.value });
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
    const { stateStore, sg } = this.props;
    if (sg && stateStore) {
      if (this.state.advanced) {
        const json = this.state.json;
        try {
          sg.startRun(JSON.parse(json));
        }
        catch (e) {
          this.setState({ error: e.toString() });
        }
      }
      else {
        try {
          const name = this.state.name;
          const port = this.state.port;
          const protocol = this.state.protocol;
          const size = stateStore.size;
          const rampSteps = stateStore.rampSteps;
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
          sg.startRun({
            addresses: _.map(_.split(this.state.host, ","), host => {
              return {
                host: _.trim(host),
                port,
                protocol
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
    const { sg } = this.props;
    if (sg) {
      sg.abortRun();
    }
  }

  private removeReport = (event: React.SyntheticEvent<HTMLButtonElement>) => {
    const { sg } = this.props;
    const id = event.currentTarget.dataset.id
    if (sg && id) {
      sg.removeReport(id);
    }
  }
}

export default App;
