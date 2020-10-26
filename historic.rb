require_relative './models/instance_calculator'
require_relative './models/instance'
require "bigdecimal"

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
header = file.first.chomp
cols = header.split('|')
cols.map! { |col| col.downcase.to_sym }
Job = Struct.new(*cols) # '*' splat operator assigns each element of
                        # cols array as an argument to the 'new' method.

include_any_node_numbers = user_args.key?('include-any-node-numbers')
max_mem = 0.0
max_mem_per_cpu = 0.0
mem_total = 0.0
mem_count = 0
cpu_count = 0
total_time = 0.0
over_resourced_count = 0
excess_nodes_count = 0
completed_jobs_count = 0
overall_any_nodes_cost = 0.0
overall_best_fit_cost = 0.0
file.readlines.each do |line|
  details = line.split("|")
  job = Job.new(*details)
  next if job.maxvmsize == "" # if empty, this is a job initiator, not a full job
  next unless PERMITTED_STATES.include?(job.state)

  time = determine_time(job.elapsed)
  next if time == 0

  completed_jobs_count += 1
  total_time += time
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

  max_rss = (job.maxrss[0...-1].to_f / 1000).ceil
  max_vm_size = (job.maxvmsize[0...-1].to_f / 1000).ceil
  mem = max_rss * 1.1
  max_mem = mem if mem > max_mem

  mem_per_cpu = (mem.to_f / cpus).ceil(2)
  max_mem_per_cpu = mem_per_cpu if mem_per_cpu > max_mem_per_cpu

  mem_total += mem
  mem_count += 1
  cpu_count += cpus

  print "Job #{job.jobid} used #{gpus} GPUs, #{cpus}CPUs & #{mem.ceil(2)}MB on #{nodes} node(s) for #{time.ceil(2)}mins. "

  instance_calculator = InstanceCalculator.new(cpus, gpus, mem, nodes, time, include_any_node_numbers)
  base_cost = instance_calculator.total_base_cost
  
  best_fit_cost = instance_calculator.total_best_fit_cost
  overall_best_fit_cost += best_fit_cost

  if instance_calculator.best_fit_count > nodes
    print "To meet requirements with identical instance types, extra nodes required. "
    excess_nodes_count += 1
  end
  if best_fit_cost > base_cost
    print "To match number of nodes, larger instance(s) than job resources require must be used. "
    over_resourced_count += 1
  end
  print "Instance config of #{instance_calculator.best_fit_description} would cost $#{best_fit_cost.ceil(2).to_f}."
  
  if include_any_node_numbers
    any_nodes_cost = instance_calculator.total_any_nodes_cost
    overall_any_nodes_cost += any_nodes_cost
    if instance_calculator.any_nodes_is_different?
      any_nodes_cost_diff = instance_calculator.any_nodes_best_fit_cost_diff
      print " Ignoring node counts, best fit would be #{instance_calculator.any_nodes_description}"
      print " at a cost of $#{any_nodes_cost.to_f.ceil(2)}"
      print any_nodes_cost_diff == 0 ? " (same cost)" : " (-$#{any_nodes_cost_diff.to_f.ceil(3)})"
      print "."
    end
  end

  puts
  puts
end

puts "-" * 50
puts "Totals"
puts

average_mem = mem_total / mem_count
average_mem_cpus = mem_total / cpu_count
puts "Total completed jobs: #{completed_jobs_count}"
puts "Average time per job: #{(total_time / completed_jobs_count).ceil(2)}mins"
puts "Average mem per job: #{average_mem.ceil(2)}MB"
puts "Average mem per cpu: #{average_mem_cpus.ceil(2)}MB"
puts "Max mem for 1 job: #{max_mem.ceil(2)}MB"
puts "Max mem per cpu: #{max_mem_per_cpu.ceil(2)}MB"
puts
if include_any_node_numbers
  puts "Overall cost ignoring node counts: $#{overall_any_nodes_cost.to_f.ceil(2)}"
  puts "Average cost per job ignoring node counts: $#{(overall_any_nodes_cost / completed_jobs_count).to_f.ceil(2)}"
end
puts "Overall best fit cost: $#{overall_best_fit_cost.to_f.ceil(2)}"
puts "Average best fit cost per job: $#{(overall_best_fit_cost / completed_jobs_count).to_f.ceil(2)}"
puts "#{over_resourced_count} jobs requiring larger instances than minimum necessary, to match number of nodes"
puts "#{excess_nodes_count} jobs requiring more nodes than used on physical cluster"
