require_relative 'instance'

class InstanceCalculator

  def initialize(total_cpus, total_gpus, total_mem, total_nodes)
    @total_cpus = total_cpus
    @total_gpus = total_gpus
    @total_mem = total_mem.to_f # in MB
    @total_nodes = total_nodes
  end

  # determine how many of the 'base' versions of the three instance types are 
  # required to meet resource needs.
  def base_instance_numbers(cpus, gpus, mem)
    instances = {gpu: 0, compute: 0, mem: 0}
    cpu_count = 0
    mem_count = 0
    # gpus are priority, as can only be given by gpu instances.
    # Additionally, gpu instances have high core counts and memory.
    if gpus > 0
      gpu_instance = Instance::AWS_INSTANCES[:gpu][:base]
      gpu_count = 0
      # If we want instances of the same type and size, all resource needs must be met by GPU instances,
      # even if this involves over resourcing
      while gpu_count < gpus || cpu_count < cpus || mem_count < mem
        instances[:gpu] += 1
        gpu_count += gpu_instance[:gpus]
        cpu_count += gpu_instance[:cpus]
        mem_count += (gpu_instance[:mem] * 1000.0) # convert GB to MB
      end
    else
      compute_instance = Instance::AWS_INSTANCES[:compute][:base]
      mem_instance = Instance::AWS_INSTANCES[:mem][:base]
      # All resource needs must be met by only compute or only mem instances,
      # even if this means over resourcing.
      last_added = nil
      while cpu_count < cpus || mem_count < mem
        to_add = :compute
        if last_added
          to_add = last_added
        else
          # A compute instance has 2GB per 1 core. If need more than this, use a mem instance,
          # which has 8GB per core.
          if cpu_count < cpus
            mem_per_cpu = (mem - mem_count) / (cpus - cpu_count)
            to_add = mem_per_cpu > 2000 ? :mem : :compute
          else
            to_add = :mem if mem - mem_count > 2000
          end
        end
        instances[to_add] = instances[to_add] += 1
        cpu_count += Instance::AWS_INSTANCES[to_add][:base][:cpus]
        mem_count += Instance::AWS_INSTANCES[to_add][:base][:mem] * 1000 # GB to MB
        last_added = to_add
      end
    end
    instances
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
