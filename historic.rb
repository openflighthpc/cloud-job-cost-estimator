require_relative './models/instance_calculator'
require_relative './models/instance'

# slurm gives remaining job times in the following formats:
# "minutes", "minutes:seconds", "hours:minutes:seconds", "days-hours",
# "days-hours:minutes" and "days-hours:minutes:seconds".
def determine_time(amount)
  return 0.0 if amount == "UNLIMITED" || amount == "NOT_SET"

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
  (seconds / 60.0)
end

user_args = Hash[ ARGV.join(' ').scan(/--?([^=\s]+)(?:=(\S+))?/) ]

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
max_mem = 0.0
max_mem_per_core = 0.0
mem_total = 0.0
mem_count = 0
cpu_count = 0
total_time = 0.0
over_resourced_count = 0
excess_nodes_count = 0
completed_jobs_count = 0
overall_base_cost = 0.0
overall_best_fit_cost = 0.0
file.readlines.each do |line|
  details = line.split("|")
  job = Job.new(*details)
  next if job.maxvmsize == "" # if empty, this is a job initiator, not a full job
  next if job.state != "COMPLETED"

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

  mem_per_core = (mem.to_f / cpus).ceil(2)
  max_mem_per_core = mem_per_core if mem_per_core > max_mem_per_core

  mem_total += mem
  mem_count += 1
  cpu_count += cpus

  print "Job #{job.jobid} used #{gpus} GPUs, #{cpus}CPUs & #{mem.ceil(2)}MB on #{nodes} node(s) for #{time.ceil(2)}mins. "

  instance_calculator = InstanceCalculator.new(cpus, gpus, mem, nodes)
  instance_numbers = instance_calculator.base_instance_numbers(cpus, gpus, mem)
  best_fit_instances = instance_calculator.best_fit_instances(instance_numbers, nodes)
  total_instances = instance_numbers.values.reduce(:+)

  cost_per_min = BigDecimal(0, 8)
  cost_per_min += instance_numbers[:gpu] * Instance::AWS_INSTANCES[:gpu][:base][:price_per_min].to_f
  cost_per_min += instance_numbers[:compute] * Instance::AWS_INSTANCES[:compute][:base][:price_per_min].to_f
  cost_per_min += instance_numbers[:mem] * Instance::AWS_INSTANCES[:mem][:base][:price_per_min].to_f
  total_cost = (cost_per_min * time)

  overall_base_cost += total_cost

  best_fit_grouped = {}
  best_fit_instances.each do |instance|
    if best_fit_grouped.has_key?(instance.name)
      best_fit_grouped[instance.name] = best_fit_grouped[instance.name] + 1
    else
      best_fit_grouped[instance.name] = 1
    end
  end

  best_fit_description = []
  best_fit_grouped.each do |k, v|
    best_fit_description << "#{v} #{k}"
  end
  best_fit_description = best_fit_description.join(", ")

  best_fit_price = 0.0
  best_fit_instances.each { |instance| best_fit_price += instance.price_per_min }
  best_fit_cost = (best_fit_price * time)

  overall_best_fit_cost += best_fit_cost

  #puts "Can be serviced by base equivalent to #{instance_numbers}"
  #puts "Base on demand cost: $#{total_cost.ceil(2)}"
  if best_fit_instances.length > nodes
    print "To meet requirements with identical instance types, extra nodes required. "
    excess_nodes_count += 1
  end
  if best_fit_cost > total_cost
    print "To meet requirements, larger instance(s) required than base equivalent. "
    over_resourced_count += 1
  end
  print "Instance config of #{best_fit_description} would cost $#{best_fit_cost.ceil(2).to_f}."
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
puts "Max mem per cpu: #{max_mem_per_core.ceil(2)}MB"
puts
puts "Overall base cost: $#{overall_base_cost.to_f.ceil(2)}"
puts "Average cost per job: $#{(overall_base_cost / completed_jobs_count).to_f.ceil(2)}"
puts "Overall best fit cost: $#{overall_best_fit_cost.to_f.ceil(2)}"
puts "#{over_resourced_count} jobs requiring larger instances than base equivalent"
puts "#{excess_nodes_count} jobs requiring more nodes than used on physical cluster"
