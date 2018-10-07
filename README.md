# Overview

Stressgrid is a software for load testing at the scale of millions of simulated users.

Stressgrid consists of two components: the generator and the coordinator.

The generator is a horizontally-scalable component that opens connections to a target server farm, generates the workload, and collects metrics.

The coordinator is a central component that orchestrates multiple generators to execute a plan. The plan specifies how many connections to maintain and for how long, and how to ramp up and wind down the workload. 

The plan also specifies scripts and their input parameters. Each connection is associated with an instance of a script and the corresponding input parameters. It executes the sequence of HTTP requests and delays that simulate a workload. A script may contain an infinite loop to simulate a long-living connection (it will get terminated during wind down phase). Or, if script exits normally, the corresponding connection closes and a new connection opens to maintain the current total number of connections. Stressgrid scripts are written in Elixir and may only use a predefined set of side-effect functions (like post and delay) to interact with the generator.

The coordinator is also responsible for metrics aggregation and reporting. It supports pluggable writers that can record metrics to a file or database for analysis and visualization. Currently, two writers are available: the CSV file writer and the CloudWatch writer. Metrics are reported every minute. Each metric can be represented by a scalar value or by a histogram. Scalar values are used for metrics that are simple counters accumulated since the beginning of the run, or during the reporting interval. Histogram metrics are used for aggregating statistics across many events that occurred during the reporting interval. Since a very large number of events—such as HTTP requests—may happen across all connections, Stressgrid uses [HDR histograms](http://hdrhistogram.org) to compress statistics. HRD histograms are compressed within each generator as events take place. Then, generators push the histograms every second to the coordinator, to further compress into the final histogram that is reported every minute to the writers.

Each generator is responsible for collecting the metrics of its own utilization, with two key metrics being collected. First is the number of connections that are currently running a script (active connections). Second is a floating point number between 0 and 1 that represents current utilization. It is very important to keep generator utilization at the healthy level (<0.8) to avoid generators becoming a bottleneck and negating the validity of a test.

# Building releases

Following are the prerequisites for building Stressgrid generator and coordinator releases:

- Elixir 1.7
- GNU C compiler (for HDR histograms)

To build the coordinator:

    $ cd coordinator
    $ MIX_ENV=prod mix deps.get
    $ MIX_ENV=prod mix release --env=prod

To build the generator:

    $ cd generator
    $ MIX_ENV=prod mix deps.get
    $ MIX_ENV=prod mix release --env=prod


# Running the coordinator

To start the coordinator in the background, run:

    $ _build/prod/rel/coordinator/bin/coordinator start

When started, it opens port 8001 for the management website, and port 8000 for generators to connect. If you are running in AWS, you need to make sure that security groups are set up to the following:

- your browser is enabled to connect to port 8001 of the coordinator;
- generators are enabled to connect to port 8000 of the coordinator;
- generators are enabled to connect to your target instances.

When using the CloudWatch report writer, you will need AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables, or your EC2 instance should have an IAM role associated with it. The only required permission is cloudwatch:PutMetricData. You also may add CW_REGION to the environment to specify in which region you would like to see the metrics.

# Running the generator(s)

For realistic workloads, you will need multiple generators, each running on a dedicated computer or cloud instance. To start the generator in the background, run:

    $ _build/prod/rel/generator/bin/generator start

The environment variable COORDINATOR_URL is required to specify the coordinator WebSocket URL, e.g. ws://10.0.0.100:8000. Note that you may need to adjust Linux kernel settings for optimal generator performance.

# Creating EC2 AMIs for generator and coordinator

To simplify running Stressgrid in EC2, we added packer scripts to create prebaked machine images.

By default, Stressgrid images are based on Debian 9 (Stretch), so you will need the same OS to build the binary releases before running packer scripts, because it simply copies the release. The packer script also includes the necessary Linux kernel settings and the Systemd service. See packer documentation for necessary AWS permissions.

To create an AMI for the coordinator:

    $ cd coordinator
    $ ./packer.sh

To create an AMI for the generator:

    $ cd coordinator
    $ ./packer.sh

When launching coordinator and generator instances, you will need to pass the corresponding configuration using EC2 user data.

Example for the coordinator:

    #!/bin/bash
    echo "CW_REGION=us-west-1" > /etc/default/sg-coordinator.env
    service sg-coordinator restart

Example for the generator:

    #!/bin/bash
    echo "COORDINATOR_URL=ws://ip-172-31-22-7.us-west-1.compute.internal:8000" > /etc/default/sg-generator.env
    service sg-generator restart

For generators, you may use the EC2 autoscale group to launch and manage the entire fleet.