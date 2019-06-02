#! /usr/bin/env node

import _ from 'lodash';
import program from 'commander';
import fs from 'fs';
import log from 'single-line-log';
import chalk from 'chalk';
import filesize from 'filesize';
import { Stressgrid, IRunPlan } from './Stressgrid'

program
  .option('-c, --coordinator-host <string>', 'coordinator host (localhost)')
  .version('0.1.0');

program
  .command('run <name> <script>')
  .description('run plan')
  .option('-t, --target-hosts <string>', 'target hosts, comma separated (localhost)')
  .option('-s, --size <number>', 'number of devices (10000)', parseInt)
  .option('--target-port <number>', 'target port (5000)', parseInt)
  .option('--target-protocol <string>', 'target protocol http|https|http2|http2s|tcp|udp (http)')
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

function runPlan(coordinatorHost: string, plan: IRunPlan) {
  let result = 0;
  let id: string | null = null;
  const sg = new Stressgrid({
    init: (grid, reports) => {
      if (!grid.telemetry.generator_count[0]) {
        console.error(chalk.red('ERROR:  must have at least one generator'));
        sg.disconnect();
        result = -1;
        return;
      }
      if (grid.run) {
        console.error(chalk.red('ERROR:  already running, please stop current run'));
        sg.disconnect();
        result = -1;
        return;
      }
      sg.run(plan);
    },
    updateGrid: (grid) => {
      if (grid.run) {
        if (id === null) {
          id = grid.run.id;
        }
        else if (id === grid.run.id) {
          if (grid.telemetry.last_script_error) {
            log.stderr.clear();
            console.error(chalk.red('ERROR:  ' + chalk.bold('line ' + grid.telemetry.last_script_error.line + ': ' + grid.telemetry.last_script_error.description)));
            sg.abortRun();
          }
          else {
            let errors = '';
            if (grid.telemetry.last_errors) {
              errors = chalk.red(_.join(_.map(_.toPairs(grid.telemetry.last_errors), pair => {
                const recentCounts = pair[1];
                const type = pair[0];
                return 'ERROR:  ' + chalk.bold(type) + ' occurred ' + chalk.bold(_.defaultTo(recentCounts[0], 0)) + ' times\r\n';
              }), ''));
            }

            log.stderr(chalk.green(
              'RUN ID: ' + chalk.bold(id) + '\n\r' +
              'STATE:  ' + chalk.bold(grid.run.state + ' ' + Math.trunc(grid.run.remaining_ms / 1000).toString() + ' seconds') + ' remaining\r\n' +
              'ACTIVE: ' + chalk.bold(_.defaultTo(grid.telemetry.active_count[0], 0).toString() + ' devices') + '\r\n' +
              'CPU:    ' + chalk.bold(Math.trunc(_.defaultTo(grid.telemetry.cpu[0], 0) * 100).toString() + '%') + '\r\n' +
              'NET RX: ' + chalk.bold(filesize(_.defaultTo(grid.telemetry.network_rx[0], 0)) + '/sec') + '\r\n' +
              'NET TX: ' + chalk.bold(filesize(_.defaultTo(grid.telemetry.network_tx[0], 0)) + '/sec') + '\r\n' +
              errors));
          }
        }
      }
    },
    addReport: (report) => {
      if (report.id === id) {
        console.log('http://' + coordinatorHost + ':8000/' + report.result.csv_url);
        sg.disconnect();
        if (report.script_error || report.errors) {
          result = -1;
        }
      }
    },
    deleteReport: (id: string) => { },
    disconnected: () => {
      process.exit(result);
    }
  });
  sg.connect('ws://' + coordinatorHost + ':8000/ws');
  process.on('SIGINT', function () {
    log.stderr.clear();
    console.error(chalk.red('ABORTED'));
    sg.abortRun();
    sg.disconnect();
    result = -1;
  });
}