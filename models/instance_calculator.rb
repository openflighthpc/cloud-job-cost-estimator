require "bigdecimal"
require_relative 'instance'

class InstanceCalculator
  attr_reader :base_instance
  attr_reader :base_instance_count

  def initialize(total_cpus, total_gpus, total_mem, total_nodes)
    @total_cpus = total_cpus
    @total_gpus = total_gpus
    @total_mem = total_mem.to_f # in MB
    @total_nodes = total_nodes
    calculate_base_instance_numbers
  end

  # determine which of the three instance types is most appropriate
  # and how many of the 'base' (smallest) instance are required
  def calculate_base_instance_numbers
    return if @base_instance

    @base_instance = nil
    @base_instance_count = 0
    gpu_count = 0
    cpu_count = 0
    mem_count = 0

    # gpus are priority, as can only be given by gpu instances.
    # Additionally, gpu instances have high core counts and memory.
    if @total_gpus > 0
      @base_instance = Instance.new(:gpu) 
    else
      # A compute instance has 2GB per 1 core. If need more than this, use a mem instance,
      # which has 8GB per cpu.
      mem_per_cpu = @total_mem / @total_cpus
      base_instance_type = mem_per_cpu > 2000 ? :mem : :compute
      @base_instance = Instance.new(base_instance_type)
    end

    while gpu_count < @total_gpus || cpu_count < @total_cpus || mem_count < @total_mem
      @base_instance_count += 1
      gpu_count += @base_instance.gpus
      cpu_count += @base_instance.cpus
      mem_count += @base_instance.mem * 1000 # convert GB to MB
    end
  end

  def base_cost_per_min
    @base_instance.cost_per_min * @base_instance_count
  end

  # Using number of 'base' instances needed, determine
  # best size and number of instances.
  def best_fit_instances(instance_numbers, nodes, consider_nodes=true)
    instances = []
    total_instances = instance_numbers.values.reduce(:+)
    if total_instances == nodes
      instance_numbers.each do |key, value|
        value.times do
          instances << Instance.new(key)
        end
      end
      return instances
    end

    type = nil
    instance_numbers.each do |k, v|
      if v > 0
        type = k
        break
      end
    end
    instances = best_fit_for_type(type, instance_numbers[type], nodes, consider_nodes)
  end

  def best_fit_for_type(type, target, nodes, consider_nodes=true)
    nodes = 1 if !consider_nodes # if ignoring actual nodes, start with fewest possible and work up
    count = 0.0
    multipliers = Instance::AWS_INSTANCES[type][:multipliers].sort
    # Unless ignoring node counts, if 1 node specified job may not be parallelizable so try to match this as
    # much as possible, giving this priority over providing exactly fitting multiple nodes of equal size.
    if nodes == 1 && consider_nodes
      best_fit = nil
      per_node = (target - count)
      multipliers.each do |m|
        if m == per_node || m > per_node
          best_fit = m
          break
        end
      end
      best_fit ||= multipliers.last
      # if needs less than that of base
      best_fit = multipliers.first if per_node < multipliers.first
      count += best_fit
      
      # if can't meet needs in one node, increase node count by one and continue
      if count < target
        nodes = 2
        count = 0.0
      else
        return [Instance.new(type, best_fit.to_i)]
      end
    end
    
    instances = []
    last_added = nil
    while count < target || nodes > 0
      best_fit = nil
      if last_added
        best_fit = last_added
      else
        per_node = (target - count) / nodes
        if multipliers.include?(per_node)
          best_fit = per_node
        elsif per_node < multipliers.first
          best_fit = multipliers.first
        else
          nodes += 1
          next
        end
      end

      instances << Instance.new(type, best_fit.to_i)
      last_added = best_fit
      count += best_fit
      nodes -= 1
    end
    instances
  end
end
