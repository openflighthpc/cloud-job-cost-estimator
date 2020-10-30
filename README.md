# cloud-job-cost-estimator

Tool for calculating suitable instances and costs for running Slurm jobs on the cloud.

## Overview

cloud-job-cost-estimator is a proof of concept Ruby application, analysing historic Slurm jobs to determine instances suitable for running them on the cloud and what this would cost.

## Installation

The application requires Ruby (2.5.1). No installation is required other than downloading the source code (via git or other means).

For Slurm to generate the data required by the application, Slurm accounting must have been set up on your cluster.

## Configuration

No configuration on the user's part is required prior to the use of this application.

### Source data and files

The application reads Slurm job data from a provided text file, with each job separated by a newline and job attributes separated by "|".

The required data in the expected format can be retrieved from Slurm using the following command, replacing the dates as desired:

```
sacct --allclusters --allusers --parsable2 --starttime 2020-09-01T00:00:00 --endtime 2020-09-30T23:59:59 -o jobid,jobname,elapsed,state,maxrss,allocgres,alloctres
```

The result must be placed in a file to be read by the application (see [operation](#operation) for more details).

### Instances Information

Details of the instance types to consider are included in the file `aws_instances.yml`. The application considers the three instance categories `gpu`, `compute` and `mem` when making its suggestions, equating to high GPU, high CPU and high memory instances respectively.

AWS costs and resources for an instance type scale proportionately with size. This file therefore contains details of the smallest ('base') instances for each of these types and the sizes available, denoted in the 'multipliers' field.

For example, the GPU instance `p3.2xlarge` has multipliers of 4 and 8. These equate to the instances `p3.8xlarge` and `p3.16xlarge`, which we know have costs, GPUs, CPUs and memory 4 and 8 times that of `p3.2xlarge` respectively.

This file is ready to use, but will require updating if these instances' resources, costs or available sizes change. The costs and size availability information currently included is that for eu-west-2 (London).

## Operation

The application can be run using `ruby analyse_jobs.rb --input=/path_to/filename`, using the path of the file you wish to analyse. Results will be printed to the console.

### Job analysis

This will determine appropriate AWS instances that would meet each completed job's GPUs, CPUs, MaxRSS (maximum memory, with an extra 10% added) and number of nodes used. Both the instance name and the number required are displayed, as well as the costs required to run those instances for the time the job took (rounded up to the nearest minute). The application will always recommend instances of the same type and size.

```
Job 001 used 16 GPUs, 32CPUs & 4181.11MB on 4 node(s) for 167mins. Instance config of 4 p3.8xlarge would cost $159.84.
Job 002 used 0 GPUs, 4CPUs & 8.81MB on 1 node(s) for 12mins. Instance config of 1 c5.xlarge would cost $0.05.
```

If a jobs' requirements cannot be met with the given number of nodes, a solution with more nodes will be suggested:

```
Job 003 used 0 GPUs, 400CPUs & 50583.51MB on 10 node(s) for 11mins. To meet requirements with identical instance types, extra nodes required. Instance config of 25 c5.4xlarge would cost $3.7.
Job 004 used 12 GPUs, 16CPUs & 8.81MB on 1 node(s) for 43mins. To meet requirements with identical instance types, extra nodes required. Instance config of 3 p3.8xlarge would cost $30.87.
```

The application will also highlight if matching the number of nodes used means using larger instance(s) than is strictly necessary to meet the job's resource needs:

```
Job 005 used 0 GPUs, 40CPUs & 8.81MB on 1 node(s) for 12mins. To meet requirements, larger instance(s) required than base equivalent. Instance config of 1 c5.12xlarge would cost $0.49.
```

All cost figures only include the core instance costs.

### Totals

The application includes a final summary of the jobs, with information regarding totals and averages. The number of jobs requiring extra nodes or over sized instances is also highlighted.

```
Totals

Total completed jobs: 578
Average time per job: 27mins
Average mem per job: 623.1MB
Average mem per cpu: 77.3MB
Max mem for 1 job: 4234.07MB
Max mem per cpu: 7044.6MB

Overall best fit cost: $23153.22
Average best fit cost per job: $40.06
35 jobs requiring larger instances than base equivalent
50 jobs requiring more nodes than used on physical cluster
```

### Optional Arguments

The application can also be run with up to four optional arguments.

#### --include-any-node-numbers

`ruby analyse_jobs.rb --input=filename.txt --include-any-node-numbers`

With this argument included, instance configurations will also be suggested with any number of nodes (regardless of how many the job actually used), if this result is different from the original suggestion. This includes the associated cost and how this differs (if at all):

```
Job 005 used 0 GPUs, 40CPUs & 8.81MB on 1 node(s) for 12mins. To meet requirements, larger instance(s) required than base equivalent. Instance config of 1 c5.12xlarge would cost $0.49. Ignoring node counts, best fit would be 5 c5.2xlarge at a cost of $0.41 (-$0.081).
Job 006 used 8 GPUs, 36CPUs & 908.6MB on 2 node(s) for 18mins. Instance config of 2 p3.8xlarge would cost $8.62. Ignoring node counts, best fit would be 1 p3.16xlarge at a cost of $8.62 (same cost).
```

These calculations will find the best suggestion with the smallest number of nodes, but there is no upper limit to how many nodes it will consider.

A summary of costs when ignoring node counts will also be added to the totals section:

```
Overall base cost (ignoring node counts): $22344.02
Average base cost per job: $38.66
```

#### --include-failed

`ruby analyse_jobs.rb --input=filename.txt --include-failed`

Under normal circumstances, this application will only include jobs that completed successfully in its calculations. Including this argument will include all jobs with any of the following states:
- COMPLETED
- FAILED
- CANCELLED
- NODE_FAIL
- OUT_OF_MEMORY
- TIMEOUT

When using this flag, most of the information in the totals section will have multiple results: a total over all jobs, and individual results for jobs grouped by state. For example:

```
--------------------------------------------------
Totals
Total jobs processed: 626 (FAILED: 77, CANCELLED: 151, TIMEOUT: 2, COMPLETED: 396)
Average time per job: 8839mins (FAILED: 1525mins, CANCELLED: 29499mins, TIMEOUT: 31mins, COMPLETED: 2427mins)
Average mem per job: 1526.83MB (FAILED: 2003.49MB, CANCELLED: 3278.51MB, TIMEOUT: 25.71MB, COMPLETED: 773.78MB)
Average mem per cpu: 152.86MB
Max mem for 1 job: 31343.89MB
Max mem per cpu: 16438.82MB
```

#### --output=

`ruby analyse_jobs.rb --input=filename.txt --output=results.csv`

Including this argument will (in addition to the console output) save results of the job analysis as a csv file, with the name of your choosing. This file will be saved in the `output` folder.

If the filename you provide is the same as a file that already exists in `output`, a prompt will ask for confirmation that you are happy to overwrite any existing data.

If both this and `--include-any-node-numbers` are used, these additional suggestions will also be in the generated file.

### --customer-facing

`ruby analyse_jobs.rb --input=filename.txt --customer-facing`

If this argument is included, generalised, customer facing names will be used for the suggested instances. Names are based upon the type of instance (GPU, Compute or Mem) and their relative size (small, medium, large, xlarge, xxlarge, etc.):

```
Job 007 used 8 GPUs, 10CPUs & 8.06MB on 1 node(s) for 2mins. Instance config of 1 GPU(large) would cost $0.96.
Job 008 used 0 GPUs, 4CPUs & 5.28MB on 1 node(s) for 92mins. Instance config of 1 Compute(medium) would cost $0.31.
Job 009 used 0 GPUs, 10CPUs & 7.17MB on 1 node(s) for 12mins. To match number of nodes, larger instance(s) than job resources require must be used. Instance config of 1 Compute(xlarge) would cost $0.17.

```
This will apply to all suggestions, including those saved to a csv if the `--output= flag` is also used.

# Contributing

Fork the project. Make your feature addition or bug fix. Send a pull
request. Bonus points for topic branches.

Read [CONTRIBUTING.md](CONTRIBUTING.md) for more details.

# Copyright and License

Eclipse Public License 2.0, see [LICENSE.txt](LICENSE.txt) for details.

Copyright (C) 2020-present Alces Flight Ltd.

This program and the accompanying materials are made available under
the terms of the Eclipse Public License 2.0 which is available at
[https://www.eclipse.org/legal/epl-2.0](https://www.eclipse.org/legal/epl-2.0),
or alternative license terms made available by Alces Flight Ltd -
please direct inquiries about licensing to
[licensing@alces-flight.com](mailto:licensing@alces-flight.com).

cloud-jobs-cost-estimator is distributed in the hope that it will be
useful, but WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, EITHER
EXPRESS OR IMPLIED INCLUDING, WITHOUT LIMITATION, ANY WARRANTIES OR
CONDITIONS OF TITLE, NON-INFRINGEMENT, MERCHANTABILITY OR FITNESS FOR
A PARTICULAR PURPOSE. See the [Eclipse Public License 2.0](https://opensource.org/licenses/EPL-2.0) for more
details.
