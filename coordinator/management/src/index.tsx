import * as _ from 'lodash';
import * as React from 'react';
import * as ReactDOM from 'react-dom';

import { Provider } from 'mobx-react';

import './App.css';

import { library } from '@fortawesome/fontawesome-svg-core'
import { faCog, faCopy, faFlag, faSpinner } from '@fortawesome/free-solid-svg-icons'

import App from './App';
import './index.css';
// import registerServiceWorker from './registerServiceWorker';

import stateStore from './stores/StateStore';

import { Stressgrid } from './Stressgrid';

library.add(faSpinner)
library.add(faCog)
library.add(faFlag)
library.add(faCopy)

const wsUrl = location.port === "3000" ?
  'ws://localhost:8000/ws' :
  (location.protocol === "https:" ? "wss:" : "ws:") + "//" + location.host + "/ws";

const sg = new Stressgrid({
  connected: () => undefined,
  disconnected: () => undefined,
  update: (state) => { stateStore.update(state); }
}, wsUrl, WebSocket);

ReactDOM.render(
  <Provider stateStore={stateStore} sg={sg}>
    <App />
  </Provider>,
  document.getElementById('root') as HTMLElement
);
// registerServiceWorker();
