#==============================================================================
# Copyright (C) 2020-present Alces Flight Ltd.
#
# This file is part of cloud-job-cost-estimator.
#
# This program and the accompanying materials are made available under
# the terms of the Eclipse Public License 2.0 which is available at
# <https://www.eclipse.org/legal/epl-2.0>, or alternative license
# terms made available by Alces Flight Ltd - please direct inquiries
# about licensing to licensing@alces-flight.com.
#
# cloud-job-cost-estimator is distributed in the hope that it will be useful, but
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, EITHER EXPRESS OR
# IMPLIED INCLUDING, WITHOUT LIMITATION, ANY WARRANTIES OR CONDITIONS
# OF TITLE, NON-INFRINGEMENT, MERCHANTABILITY OR FITNESS FOR A
# PARTICULAR PURPOSE. See the Eclipse Public License 2.0 for more
# details.
#
# You should have received a copy of the Eclipse Public License 2.0
# along with cloud-job-cost-estimator. If not, see:
#
#  https://opensource.org/licenses/EPL-2.0
#
# For more information on cloud-job-cost-estimator, please visit:
# https://github.com/openflighthpc/cloud-job-cost-estimator
#==============================================================================

require_relative './models/instance_calculator'
require_relative './models/instance'
require "bigdecimal"
require 'csv'

# slurm gives job times in the following formats:
# "minutes", "minutes:seconds", "hours:minutes:seconds", "days-hours",
# "days-hours:minutes" and "days-hours:minutes:seconds".
def determine_time(amount)
  days = false
  seconds = 0.0
  if amount.include?("-")
    amount = amount.split("-")
    return 0.0 if amount[0].to_i > 300 # don't include jobs where slurm decides it will take a year

    days = true
    seconds += amount[0].to_i * 24 * 60 * 60 # days
    amount = amount[1]
  end
  amount = amount.split(":")
  if amount.length == 1
    if days
      seconds += amount[0].to_i * 60 * 60 # hours
    else
      seconds += amount[0].to_i * 60 # minutes
    end
  elsif amount.length == 2
    if days
      seconds += amount[0].to_i * 60 * 60 # hours
      seconds += amount[1].to_i * 60 # minutes
    else
      seconds += amount[0].to_i * 60 # minutes
      seconds += amount[1].to_i # seconds
    end
  else
    seconds += amount[0].to_i * 60 * 60 # hours
    seconds += amount[1].to_i * 60 # minutes
    seconds += amount[2].to_i # seconds
  end
  seconds / 60.0
end

def print_state_cost_totals(states, cost_type)
  print " ("
  print states.map { |state, jobs|
    job_str = jobs.map { |job| job[cost_type] }.reduce(&:+).to_f.ceil(2)
    "#{state}: $#{job_str}" if job_str > 0
  }.compact.join(', ')
  print ")"
end

def print_state_averages(states, attribute, unit)
  print " ("
  print states.map { |state, jobs|
    job_str = begin
                (jobs.map { |job| job[attribute] }.reduce(&:+).to_f / jobs.length).ceil(2)
              rescue NoMethodError
                0
              end
    "#{state}: #{"$" if unit == "$"}#{job_str}#{unit if unit != "$"}" if job_str > 0
  }.compact.join(', ')
  print ")"
end

user_args = Hash[ ARGV.join(' ').scan(/--?([^=\s]+)(?:=(\S+))?/) ]
PERMITTED_STATES = user_args.key?('include-failed') ?
  %w(FAILED CANCELLED NODE_FAIL OUT_OF_MEMORY TIMEOUT COMPLETED) :
  %w(COMPLETED)

begin
  file = File.open(user_args['input'])
rescue TypeError
  puts 'Please specify an input file.'
  exit 1
end

# initalise hash with one key per permitted state
# each having an empty array as the value
states = Hash[PERMITTED_STATES.collect { |x| [x, [] ] } ]
state_times = Hash[PERMITTED_STATES.collect { |x| [x, 0] } ]

include_any_node_numbers = user_args.key?('include-any-node-numbers')
customer_facing = user_args.key?('customer-facing')
output = user_args['output'] ? "output/#{user_args['output']}" : nil
provider = user_args['provider'] ? user_args['provider'].downcase.to_sym : :aws
if ![:aws, :azure].include?(provider)
  puts 'Please specify a valid cloud provider. AWS and Azure are currently supported.'
  exit 1
end

if output
  if File.file?(output)
    valid = false
    while !valid
      print "File #{output} already exists. This file will be overwritten, do you wish to continue (y/n)? "
      choice = STDIN.gets.chomp.downcase
      if choice == "y"
        valid = true
      elsif choice == "n"
        return
      else
        puts "Invalid selection, please try again."
      end
    end
  end

  csv_headers = %w[job_id state gpus cpus base_max_rss_mb adjusted_max_rss_mb num_nodes 
                   elapsed_mins suggested_num suggested_type suggested_cost_usd]
  csv_headers.concat(%w[any_nodes_num any_nodes_type any_nodes_cost_usd cost_diff_usd]) if include_any_node_numbers
  CSV.open(output, "wb") do |csv|
    csv << csv_headers
  end
end


header = file.first.chomp
cols = header.split('|')
cols.map! { |col| col.downcase.to_sym }
Job = Struct.new(*cols) # '*' splat operator assigns each element of
                        # cols array as an argument to the 'new' method.

max_mem = 0.0
max_mem_per_cpu = 0.0
mem_total = 0.0
mem_count = 0
cpu_count = 0
over_resourced_count = 0
excess_nodes_count = 0
overall_any_nodes_cost = 0.0
overall_best_fit_cost = 0.0
file.readlines.each do |line|
  details = line.split("|")
  job = Job.new(*details)
  next if job.maxvmsize == "" # if empty, this is a job initiator, not a full job
  next unless states.key?(job.state)

  time = determine_time(job.elapsed)
  next if time == 0

  state_times[job.state] += time
  time = time.ceil
  gpus = job.reqgres.split(":")[1].to_i

  allocated = job.alloctres
  allocated_details = {}
  allocated.split(",").each  do |part|
    key_values = part.split("=")
    allocated_details[key_values[0]] = key_values[1]&.chomp
  end

  cpus = allocated_details["cpu"].to_i
  nodes = allocated_details["node"].to_i

  max_rss = (job.maxrss[0...-1].to_f / 1000)
  max_vm_size = (job.maxvmsize[0...-1].to_f / 1000).ceil
  mem = max_rss * 1.1
  max_mem = mem if mem > max_mem

  mem_per_cpu = (mem.to_f / cpus).ceil(2)
  max_mem_per_cpu = mem_per_cpu if mem_per_cpu > max_mem_per_cpu

  mem_total += mem
  mem_count += 1
  cpu_count += cpus

  msg = "Job #{job.jobid} used #{gpus} GPUs, #{cpus}CPUs & #{mem.ceil(2)}MB on #{nodes} node(s) for #{time.ceil(2)}mins. "

  instance_calculator = InstanceCalculator.new(cpus, gpus, mem, nodes, time, include_any_node_numbers, customer_facing, provider)
  base_cost = instance_calculator.total_base_cost
  
  best_fit_cost = instance_calculator.total_best_fit_cost

  if instance_calculator.best_fit_count > nodes
    msg << "To meet requirements with identical instance types, extra nodes required. "
    excess_nodes_count += 1
  end
  if best_fit_cost > base_cost
    msg << "To match number of nodes, larger instance(s) than job resources require must be used. "
    over_resourced_count += 1
  end
  msg << "Instance config of #{instance_calculator.best_fit_description} would cost $#{best_fit_cost.ceil(2).to_f}."

  if include_any_node_numbers
    any_nodes_cost = instance_calculator.total_any_nodes_cost
    overall_any_nodes_cost += any_nodes_cost
    if instance_calculator.any_nodes_is_different?
      any_nodes_cost_diff = instance_calculator.any_nodes_best_fit_cost_diff
      msg << " Ignoring node counts, best fit would be #{instance_calculator.any_nodes_description}"
      msg << " at a cost of $#{any_nodes_cost.to_f.ceil(2)}"
      msg << (any_nodes_cost_diff == 0 ? " (same cost)" : " (-$#{any_nodes_cost_diff.to_f.ceil(3)})")
      msg << "."
    end
  end

  states[job.state] << { message: msg, time: time, mem: mem, best_fit_cost: best_fit_cost, any_nodes_cost: any_nodes_cost }
  if output
    CSV.open(output, "ab") do |csv|
      results = ["'#{job.jobid}", job.state, gpus, cpus, max_rss, mem.ceil(2), nodes, time,
                 instance_calculator.best_fit_count, instance_calculator.best_fit_name, best_fit_cost.to_f]
      if include_any_node_numbers
        results.concat([instance_calculator.any_nodes_count, instance_calculator.any_nodes_name])
        results.concat([instance_calculator.total_any_nodes_cost.to_f, instance_calculator.any_nodes_best_fit_cost_diff.to_f])  
      end
      csv << results
    end
  end
end

states.each do |state, jobs|
  next if !jobs.any?
  puts state
  puts "#{'-'*50}\n"
  puts jobs.map { |job| job[:message] }
  puts
end

puts "-" * 50
puts "Totals\n"

total_time = states.values.flatten.map { |job| job[:time] }.reduce(&:+)
total_jobs_count = states.values.flatten.count

average_mem = mem_total / mem_count
average_mem_cpus = mem_total / cpu_count

overall_best_fit_cost = states.values.flatten.map { |job| job[:best_fit_cost] }.reduce(&:+)

print "Total jobs processed: #{total_jobs_count}"
if states.count > 1 
  print " ("
  print states.map { |state, jobs| "#{state}: #{jobs.count}" if jobs.count > 0 }.compact.join(', ')
  print ")"
end
puts
print "Average time per job: #{(total_time / total_jobs_count).ceil(2)}mins"
print_state_averages(states, :time, "mins") if states.count > 1
puts
print "Average mem per job: #{average_mem.ceil(2)}MB"
print_state_averages(states, :mem, "MB") if states.count > 1
puts

puts "Average mem per cpu: #{average_mem_cpus.ceil(2)}MB"
puts "Max mem for 1 job: #{max_mem.ceil(2)}MB"
puts "Max mem per cpu: #{max_mem_per_cpu.ceil(2)}MB"
puts
if include_any_node_numbers
  print "Overall cost ignoring node counts: $#{overall_any_nodes_cost.to_f.ceil(2)}"
  print_state_cost_totals(states, :any_nodes_cost) if states.count > 1
  puts
  print "Average cost per job ignoring node counts: $#{(overall_any_nodes_cost / total_jobs_count).to_f.ceil(2)}"
  print_state_averages(states, :any_nodes_cost, "$") if states.count > 1
  puts
end
print "Overall best fit cost: $#{overall_best_fit_cost.to_f.ceil(2)}"
print_state_cost_totals(states, :best_fit_cost) if states.count > 1
puts

print "Average best fit cost per job: $#{(overall_best_fit_cost / total_jobs_count).to_f.ceil(2)}"
print_state_averages(states, :best_fit_cost, "$") if states.count > 1
puts

puts "#{over_resourced_count} jobs requiring larger instances than minimum necessary, to match number of nodes"
puts "#{excess_nodes_count} jobs requiring more nodes than used on physical cluster"
puts

puts "-" * 50
puts "Instances Summary"
puts

puts "Best Fit"
puts InstanceCalculator.grouped_best_fit_description(customer_facing, provider)

if include_any_node_numbers
  puts "\nIgnoring node counts"
  puts InstanceCalculator.grouped_any_nodes_description(customer_facing, provider)
end
