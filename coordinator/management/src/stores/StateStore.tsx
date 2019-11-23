import * as filesize from 'filesize';
import * as _ from 'lodash';
import { action, computed, observable } from 'mobx';
import { IState } from '../Stressgrid';

export function formatCpu(value: number) {
  return value.toString() + ' %';
}

export function showCpuWarning(value: number) {
  return value > 80;
}

export class StateStore {
  @observable public state: IState = {};
  @observable public desiredSize: number = 10000;

  @action public clear = () => {
    this.state = {};
  }

  @action public update = (state: IState) => {
    this.state = _.clone(_.assign(this.state, state));
  }

  private makeSparkline(key: string): number[] {
    return this.state.stats ? _.reject(_.reverse(_.clone(this.state.stats[key])), v => v === null) : [];
  }

  private makeValue<T>(key: string, format: (v: number) => T, def: T): T {
    if (this.state.stats && this.state.stats[key]) {
      const value = _.first(this.state.stats[key]);
      if (_.isNumber(value)) {
        return format(value);
      }
    }
    return def;
  }

  @computed get cpuSparkline(): number[] {
    return this.makeSparkline('cpu_percent');
  }

  @computed get cpu(): string {
    return this.makeValue('cpu_percent', formatCpu, '-');
  }

  @computed get cpuWarning(): boolean {
    return this.makeValue('cpu_percent', showCpuWarning, false);
  }

  @computed get networkRxSparkline(): number[] {
    return this.makeSparkline('network_rx_bytes_per_second');
  }

  @computed get networkRx(): string {
    return this.makeValue('network_rx_bytes_per_second', (v) => filesize(v) + '/sec', '-');
  }

  @computed get networkTxSparkline(): number[] {
    return this.makeSparkline('network_tx_bytes_per_second');
  }

  @computed get networkTx(): string {
    return this.makeValue('network_tx_bytes_per_second', (v) => filesize(v) + '/sec', '-');
  }

  @computed get activeDeviceNumberSparkline(): number[] {
    return this.makeSparkline('active_device_number');
  }

  @computed get activeDeviceNumber(): string {
    return this.makeValue('active_device_number', (v) => v.toString(), '-');
  }

  @computed get generatorCount() {
    return _.defaultTo(this.state.generator_count, 0);
  }

  @computed get rampStepSize() {
    return this.generatorCount * 10;
  }

  @computed get rampSteps() {
    return Math.trunc(this.desiredSize / this.rampStepSize);
  }

  @computed get size() {
    return this.rampSteps * this.rampStepSize
  }
}

const store = new StateStore();
export default store;