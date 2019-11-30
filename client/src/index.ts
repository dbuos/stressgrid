#! /usr/bin/env node

import _ from 'lodash';
import program from 'commander';
import fs from 'fs';
import log from 'single-line-log';
import chalk from 'chalk';
import filesize from 'filesize';
import columnify from 'columnify';
import WS from 'ws';
import { Stressgrid, IRunPlan, IRun, IStats } from './Stressgrid'

program
  .option('-c, --coordinator-host <string>', 'coordinator host (localhost)')
  .version('0.1.0');

program
  .command('run <name> <script>')
  .description('run plan')
  .option('-t, --target-hosts <string>', 'target hosts, comma separated (localhost)')
  .option('-s, --size <number>', 'number of devices (10000)', parseInt)
  .option('--target-port <number>', 'target port (5000)', parseInt)
  .option('--target-protocol <string>', 'target protocol http10|http10s|http|https|http2|http2s|tcp|udp (http)')
  .option('--script-params <json>', 'script parameters ({})')
  .option('--rampup <number>', 'rampup seconds (900)', parseInt)
  .option('--sustain <number>', 'sustain seconds (900)', parseInt)
  .option('--rampdown <number>', 'rampdown seconds (900)', parseInt)
  .action((name, script, options) => {
    const coordinatorHost = _.defaultTo(program.coordinatorHost, 'localhost');
    if (!fs.existsSync(script)) {
      console.error('script file must exist');
      process.exit(-1);
    }
    const plan: IRunPlan = {
      addresses: _.map(_.split(_.defaultTo(options.targetHosts, 'localhost'), ','), host => {
        return {
          host: _.trim(host),
          port: _.defaultTo(options.targetPort, 5000),
          protocol: _.defaultTo(options.targetProtocol, 'http')
        };
      }),
      blocks: [{
        params: JSON.parse(_.defaultTo(options.scriptParams, '{}')),
        size: _.defaultTo(options.size, 10000)
      }],
      name,
      opts: {
        ramp_steps: 1000,
        rampdown_step_ms: _.defaultTo(options.rampdown, 900),
        rampup_step_ms: _.defaultTo(options.rampup, 900),
        sustain_ms: _.defaultTo(options.sustain, 900) * 1000
      },
      script: fs.readFileSync(script).toString()
    };
    runPlan(coordinatorHost, plan);
  });

program.parse(process.argv);

if (!process.argv.slice(2).length) {
  program.outputHelp();
}

function generatorCountRows(generatorCount: number) {
  let color = "green";
  if (generatorCount === 0) {
    color = "red";
  }
  return [
    { pos: "0", name: chalk[color]("Available generators"), value: chalk[color].bold(generatorCount.toString()) }
  ];
}

function runRows(run: IRun | null) {
  if (run) {
    return [
      { pos: "1", name: chalk.green("Run id"), value: chalk.green.bold(run.id) },
      { pos: "2", name: chalk.green("Run state"), value: chalk.green.bold(run.state) },
      { pos: "3", name: chalk.green("In-state remaining time"), value: chalk.green.bold(Math.trunc(run.remaining_ms / 1000).toString() + ' seconds') }
    ];
  }
  return [];
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

function statsRows(liveReport: IStats<number[]> | null) {
  if (liveReport) {
    return _.map(liveReport, (values, key) => {
      let color = "green";
      if (statsError(key)) {
        color = "red";
      }
      if (key === "cpu_percent") {
        if (statsRedCpuPercent(values)) {
          color = "red";
        }
      }
      return { pos: key, name: chalk[color](statsName(key)), value: chalk[color].bold(statsValue(key, values)) };
    });
  }
  return [];
}

function updateScreen(generatorCount: number, run: IRun | null, stats: IStats<number[]> | null) {
  log.stderr(
    columnify(
      _.map(
        _.sortBy(
          _.concat(
            generatorCountRows(generatorCount),
            runRows(run),
            statsRows(stats)
          ),
          row => row.pos
        ),
        row => _.omit(row, 'pos')
      ),
      { showHeaders: false }
    ) +
    '\n'
  );
}

function runPlan(coordinatorHost: string, plan: IRunPlan) {
  let currentGeneratorCount: number = 0;
  let currentRun: IRun | null = null;
  let currentStats: IStats<number[]> | null = null;

  const sg = new Stressgrid({
    update: (state) => {
      if (state.generator_count !== undefined) {
        currentGeneratorCount = state.generator_count;
      }
      if (state.stats !== undefined) {
        currentStats = state.stats;
      }
      if (state.run !== undefined) {
        if (state.run) {
          if (currentRun) {
            if (state.run.id === currentRun.id) {
              currentRun = state.run;
            }
            else {
              log.stderr.clear();
              log.stderr(chalk.red('There is current run with different id!\n'));
              sg.disconnect();
              process.exitCode = -1;
              return;
            }
          }
          else {
            if (state.run.name === plan.name) {
              currentRun = state.run;
            }
            else {
              log.stderr.clear();
              log.stderr(chalk.red('There is current run with different name!\n'));
              sg.disconnect();
              process.exitCode = -1;
              return;
            }
          }
        }
      }
      if (state.reports !== undefined) {
        const report = _.first(state.reports);
        if (report && currentRun && report.id === currentRun.id) {
          log.stderr.clear();
          log.stderr('');
          log.stdout('http://' + coordinatorHost + ':8000/' + report.result.csv_url + '\n');
          sg.disconnect();
          return;
        }
      }
      if (state.last_script_error !== undefined) {
        if (state.last_script_error !== null) {
          log.stderr.clear();
          log.stderr(chalk.red('Error in script:  ' + chalk.bold('line ' + state.last_script_error.line + ': ' + state.last_script_error.description) + '\n'));
          sg.abortRun();
          sg.disconnect();
          process.exitCode = -1;
          return;
        }
      }

      updateScreen(currentGeneratorCount, currentRun, currentStats);
    },
    connected: () => { sg.startRun(plan); },
    disconnected: () => { }
  });
  sg.connect('ws://' + coordinatorHost + ':8000/ws', WS);
  process.on('SIGINT', function () {
    log.stderr.clear();
    log.stderr(chalk.red('Run aborted!\n'));
    sg.abortRun();
    sg.disconnect();
    process.exitCode = -1;
  });
}