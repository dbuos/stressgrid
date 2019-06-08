import * as _ from 'lodash';
import * as React from 'react';
import * as ReactDOM from 'react-dom';

import { Provider } from 'mobx-react';

import './App.css';

import { library } from '@fortawesome/fontawesome-svg-core'
import { faCog, faFlag, faSpinner } from '@fortawesome/free-solid-svg-icons'

import App from './App';
import './index.css';
// import registerServiceWorker from './registerServiceWorker';

import reportsStore from './stores/ReportsStore';
import runStore from './stores/RunStore';
import telemetryStore from './stores/TelemetryStore';

import { IGrid, IReport, Stressgrid } from './Stressgrid';

library.add(faSpinner)
library.add(faCog)
library.add(faFlag)

const wsUrl = location.port === "3000" ?
  'ws://localhost:8000/ws' :
  (location.protocol === "https:" ? "wss:" : "ws:") + "//" + location.host + "/ws";

function updateGrid(g: IGrid) {
  const t = g.telemetry;
  telemetryStore.update(
    t.last_script_error ? t.last_script_error.description : null,
    t.last_errors ? t.last_errors : null,
    t.cpu,
    t.network_rx,
    t.network_tx,
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

function addReport(r: IReport) {
  reportsStore.addReport(r.id,
    {
      csvUrl: r.result.csv_url,
      cwUrl: r.result.cw_url,
      hasNonScriptErrors: !!r.errors,
      hasScriptErrors: !!r.script_error,
      maxCpu: r.max_cpu,
      maxNetworkRx: r.max_network_rx,
      maxNetworkTx: r.max_network_tx,
      name: r.name
    });
}

const sg = new Stressgrid({
  addReport: (report: IReport) => {
    addReport(report);
  },
  deleteReport: (id: string) => {
    reportsStore.deleteReport(id);
  },
  disconnected: () => undefined,
  init: (grid: IGrid, reports: IReport[]) => {
    telemetryStore.clear();
    runStore.clear();
    reportsStore.clear();

    updateGrid(grid);
    _.forEach(reports, r => addReport(r));
  },
  updateGrid: (grid: IGrid) => {
    updateGrid(grid);
  }
});

sg.connect(wsUrl, WebSocket);

ReactDOM.render(
  <Provider telemetryStore={telemetryStore} runStore={runStore} reportsStore={reportsStore} sg={sg}>
    <App />
  </Provider>,
  document.getElementById('root') as HTMLElement
);
// registerServiceWorker();
