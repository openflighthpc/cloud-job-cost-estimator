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
  (seconds / 60.0).ceil
end

file = File.open('frank_september_jobs.txt')
#file = File.open('hamilton_queue_sept.txt')
max_mem = 0.0
max_mem_per_core = 0.0
mem_total = 0.0
mem_count = 0
cpu_count = 0
over_resourced_count = 0
under_resourced_count = 0
completed_jobs_count = 0
overall_base_cost = 0.0
overall_best_fit_cost = 0.0
file.readlines.each_with_index do |line, index|
  if index != 0
    details = line.split("|")
    next if details[4] == "" # if empty, this is a job initiator, not a full job
    next if details[23] != "COMPLETED"
    
    completed_jobs_count += 1
    time = determine_time(details[22])
    gpus = details[40].split(":")[1].to_i
    
    allocated = details[42]
    allocated_details = {}
    allocated.split(",").each  do |part|
      key_values = part.split("=")
      allocated_details[key_values[0]] = key_values[1]&.chomp
    end
    
    cpus = allocated_details["cpu"].to_i
    # mem = allocated_details["mem"]
    # if mem
    #   mem = mem.include?("M") ? (mem.gsub("M", "").to_i / 1000.0) : mem.gsub("GB", "").to_i
    # end
    # mem ||= 0.0
    nodes = allocated_details["node"].to_i

    max_rss = (details[8][0...-1].to_f / 1000).ceil
    max_vm_size = (details[4][0...-1].to_f / 1000).ceil
    mem = max_rss * 1.1
    #mem = max_vm_size
    #mem = [max_rss, max_vm_size].max
    max_mem = mem if mem > max_mem

    mem_per_core = (mem.to_f / cpus).ceil(2)
    max_mem_per_core = mem_per_core if mem_per_core > max_mem_per_core

    mem_total += mem
    mem_count += 1
    cpu_count += cpus

    print "Job #{details[0]} used #{gpus} GPUs, #{cpus}CPUs & #{mem.ceil(2)}MB on #{nodes}node(s) for #{time.ceil(2)}mins. "
    
    instance_calculator = InstanceCalculator.new(cpus, gpus, mem, nodes)
    instance_numbers = instance_calculator.base_instance_numbers(cpus, gpus, mem)
    best_fit_instances = instance_calculator.best_fit_instances(instance_numbers, nodes)
    total_instances = instance_numbers.values.reduce(:+)

    cost_per_min = 0.0
    cost_per_min += instance_numbers[:gpu] * Instance::AWS_INSTANCES[:gpu][:base][:price_per_min]
    cost_per_min += instance_numbers[:compute] * Instance::AWS_INSTANCES[:compute][:base][:price_per_min]
    cost_per_min += instance_numbers[:mem] * Instance::AWS_INSTANCES[:mem][:base][:price_per_min]
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

    if best_fit_cost.ceil(2) != total_cost.ceil(2)
      if best_fit_cost < total_cost
        puts "No AWS instance combination exists that can acheive the needed resources in that many nodes"
        under_resourced_count += 1
      else
        puts "To meet requirements, larger instance(s) required than base equivalent"
        over_resourced_count += 1
      end
      print "Closest match:  #{best_fit_description} at cost of $#{best_fit_cost.ceil(2)}"
    else
      print "Instance config of #{best_fit_description} would cost $#{best_fit_cost.ceil(2)}"
    end
    puts
    puts
  end
end

puts "-" * 50
puts "Totals"
puts

average_mem = mem_total / mem_count
average_mem_cpus = mem_total / cpu_count
puts "Total completed jobs: #{completed_jobs_count}"
puts "Max mem for 1 job: #{max_mem.ceil(2)}MB"
puts "Max mem per core: #{max_mem_per_core.ceil(2)}MB"
puts "Average mem per job: #{average_mem.ceil(2)}MB"
puts "Average mem per cpu: #{average_mem_cpus.ceil(2)}MB"
puts
puts "Overall base cost: $#{overall_base_cost.ceil(2)}"
puts "Average cost per job: $#{(overall_base_cost / completed_jobs_count).ceil(2)}"
puts "Overall best fit cost: $#{overall_best_fit_cost.ceil(2)}"
puts "#{over_resourced_count} jobs requiring larger instances than base equivalent"
puts "#{under_resourced_count} jobs where no equivalent AWS instance combinations will meet all job requirements"
