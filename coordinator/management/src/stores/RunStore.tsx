import * as _ from 'lodash';
import { action, observable } from 'mobx';

export class RunStore {
  @observable public id: string | null;
  @observable public name: string | null;
  @observable public remainingMs: number | null;
  @observable public state: string | null;

  @action public clear = () => {
    this.id = null;
    this.name = null;
    this.remainingMs = null;
    this.state = null;
  }

  @action public update = (id: string, name: string, state: string, remainingMs: number) => {
    this.id = id;
    this.name = name;
    this.state = state;
    this.remainingMs = remainingMs;
  }
}

const store = new RunStore();
export default store;