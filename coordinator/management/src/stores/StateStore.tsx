import * as _ from 'lodash';
import { action, computed, observable } from 'mobx';
import { IState } from '../Stressgrid';

export class StateStore {
  @observable public state: IState = {};
  @observable public desiredSize: number = 10000;

  @action public clear = () => {
    this.state = {};
  }

  @action public update = (state: IState) => {
    this.state = _.clone(_.assign(this.state, state));
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