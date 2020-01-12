#! /usr/bin/env node

import _ from "lodash";
import program from "commander";
import fs from "fs";
import chalk, { Chalk } from "chalk";
import filesize from "filesize";
import columnify from "columnify";
import WS from "ws";
import { Stressgrid, RunPlan, Run, Statistics } from "./Stressgrid"

program
  .option("-c, --coordinator-host <string>", "coordinator host (localhost)")
  .version("0.1.0");

program
  .command("run <name> <script>")
  .description("run plan")
  .option("-t, --target-hosts <string>", "target hosts, comma separated (localhost)")
  .option("-s, --size <number>", "number of devices (10000)", parseInt)
  .option("--target-port <number>", "target port (5000)", parseInt)
  .option("--target-protocol <string>", "target protocol http10|http10s|http|https|http2|http2s|tcp|udp (http)")
  .option("--script-params <json>", "script parameters ({})")
  .option("--rampup <number>", "rampup seconds (900)", parseInt)
  .option("--sustain <number>", "sustain seconds (900)", parseInt)
  .option("--rampdown <number>", "rampdown seconds (900)", parseInt)
  .action((name, script, options) => {
    const coordinatorHost = _.defaultTo(program.coordinatorHost, "localhost");
    if (!fs.existsSync(script)) {
      console.error("Script not found");
      process.exit(-1);
    }
    const plan: RunPlan = {
      addresses: _.map(_.split(_.defaultTo(options.targetHosts, "localhost"), ","), host => {
        return {
          host: _.trim(host),
          port: _.defaultTo(options.targetPort, 5000),
          protocol: _.defaultTo(options.targetProtocol, "http")
        };
      }),
      blocks: [{
        params: JSON.parse(_.defaultTo(options.scriptParams, "{}")),
        script: fs.readFileSync(script).toString(),
        size: _.defaultTo(options.size, 10000)
      }],
      name,
      opts: {
        ramp_steps: 1000,
        rampdown_step_ms: _.defaultTo(options.rampdown, 900),
        rampup_step_ms: _.defaultTo(options.rampup, 900),
        sustain_ms: _.defaultTo(options.sustain, 900) * 1000
      }
    };
    runPlan(coordinatorHost, plan);
  });

program.parse(process.argv);

if (!process.argv.slice(2).length) {
  program.outputHelp();
}

interface Row {
  pos: string;
  name: string;
  value: string;
}

function generatorCountRows(generatorCount: number): Row[] {
  let color: keyof Chalk = "green";
  if (generatorCount === 0) {
    color = "red";
  }
  return [
    { pos: "0", name: chalk[color]("Available generators"), value: generatorCount.toString() }
  ];
}

function runRows(run: Run | null): Row[] {
  if (run) {
    return [
      { pos: "1", name: chalk.green("Run id"), value: run.id },
      { pos: "2", name: chalk.green("Run state"), value: run.state },
      { pos: "3", name: chalk.green("In-state remaining time"), value: Math.trunc(run.remaining_ms / 1000).toString() + " seconds" }
    ];
  }
  return [];
}

const redCpuPercent = 80;

function statsRedCpuPercent(values: number[]): boolean {
  const value = _.first(values);
  return _.isNumber(value) && value > redCpuPercent;
}

const bytesPerSecondRegex = /(.*)_bytes_per_second$/;
const perSecondRegex = /(.*)_per_second$/;
const percentRegex = /(.*)_percent$/;
const microsecondRegex = /(.*)_us$/;
const bytesCountRegex = /(.*)_bytes_count$/;
const countRegex = /(.*)_count$/;
const numberRegex = /(.*)_number$/;
const errorRegex = /(.*)_error$/;

function statsNameAndError(key: string): { name: string, error: boolean } {
  let r: RegExpExecArray | null;
  r = bytesPerSecondRegex.exec(key);
  if (r !== null) {
    return { name: _.startCase(r[1]) + " (throughput)", error: false };
  }
  r = perSecondRegex.exec(key)
  if (r !== null) {
    let name = r[1];
    let error = false;
    r = errorRegex.exec(name);

    if (r !== null) {
      name = r[1];
      error = true;
    }
    return { name: _.startCase(name) + " (rate)", error };
  }
  r = percentRegex.exec(key)
  if (r !== null) {
    return { name: _.startCase(r[1]) + " (load)", error: false };
  }
  r = r = microsecondRegex.exec(key)
  if (r !== null) {
    return { name: _.startCase(r[1]) + " (time)", error: false };
  }
  r = bytesCountRegex.exec(key);
  if (r !== null) {
    return { name: _.startCase(r[1]) + " (volume)", error: false };
  }
  r = countRegex.exec(key);
  if (r !== null) {
    let name = r[1];
    let error = false;
    r = errorRegex.exec(name);

    if (r !== null) {
      name = r[1];
      error = true;
    }
    return { name: _.startCase(name) + " (count)", error };
  }
  r = numberRegex.exec(key)
  if (r !== null) {
    return { name: _.startCase(r[1]) + " (number)", error: false };
  }

  return { name: _.startCase(key), error: false };
}

const commaRegex = /\B(?=(\d{3})+(?!\d))/g;

function statsValue(key: string, values: number[]): string {
  const value = _.first(values);
  if (_.isNumber(value)) {
    if (bytesPerSecondRegex.test(key)) {
      return filesize(value) + "/sec";
    }
    if (perSecondRegex.test(key)) {
      return value.toString().replace(commaRegex, ",") + " /sec";
    }
    if (percentRegex.test(key)) {
      return Math.trunc(value).toString() + " %";
    }
    if (microsecondRegex.test(key)) {
      if (value >= 1000000) {
        return Math.trunc(value / 1000000).toString() + " seconds";
      }
      if (value >= 1000) {
        return Math.trunc(value / 1000).toString() + " milliseconds";
      }
      return value.toString() + " microseconds";
    }
    if (bytesCountRegex.test(key)) {
      return filesize(value);
    }
    if (countRegex.test(key)) {
      return value.toString().replace(commaRegex, ",");
    }
    if (numberRegex.test(key)) {
      return value.toString().replace(commaRegex, ",");
    }

    return value.toString();
  }

  return "-";
}

function statsRows(statistics: Statistics<number[]> | null): Row[] {
  if (statistics) {
    return _.map(statistics, (values, key) => {
      const { name, error } = statsNameAndError(key);
      let color: keyof Chalk = error ? "red" : "green";
      if (key === "cpu_percent") {
        if (statsRedCpuPercent(values)) {
          color = "red";
        }
      }
      return { pos: key, name: chalk[color](name), value: statsValue(key, values) };
    });
  }
  return [];
}

function updateScreen(generatorCount: number, run: Run | null, stats: Statistics<number[]> | null): void {
  console.error(
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
        row => _.omit(row, "pos")
      ),
      { showHeaders: false }
    ) +
    "\n"
  );
}

function runPlan(coordinatorHost: string, plan: RunPlan): void {
  let currentGeneratorCount: number = 0;
  let currentRun: Run | null = null;
  let currentStats: Statistics<number[]> | null = null;

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
              console.error(chalk.red("There is current run with different id!"));
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
              console.error(chalk.red("There is current run with different name!"));
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
          console.log("http://" + coordinatorHost + ":8000/" + report.result.csv_url);
          sg.disconnect();
          return;
        }
      }
      if (state.last_script_error !== undefined) {
        if (state.last_script_error !== null) {
          console.log(chalk.red("Error in script at line " + state.last_script_error.line + ": " + state.last_script_error.description));
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
  }, "ws://" + coordinatorHost + ":8000/ws", WS);
  process.on("SIGINT", function () {
    console.log(chalk.red("Run aborted!"));
    sg.abortRun();
    sg.disconnect();
    process.exitCode = -1;
  });
}