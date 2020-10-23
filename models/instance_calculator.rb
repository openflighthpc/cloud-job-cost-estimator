require_relative 'instance'

class InstanceCalculator

  def initialize(total_cpus, total_gpus, total_mem, total_nodes)
    @total_cpus = total_cpus
    @total_gpus = total_gpus
    @total_mem = total_mem
    @total_nodes = total_nodes
  end

  def base_instance_numbers(cpus, gpus, mem)
    instances = {gpu: 0, compute: 0, mem: 0}
    cpu_count = 0
    mem_count = 0
    # gpus are priority, as can only be given by gpu instances.
    # Additionally, gpu instances have high core counts and memory.
    if gpus > 0
      gpu_instance = Instance::AWS_INSTANCES[:gpu][:base]
      gpu_count = 0
      while gpu_count < gpus
        instances[:gpu] += 1
        gpu_count += gpu_instance[:gpus]
      end
      cpu_count += instances[:gpu] * gpu_instance[:cpus]
      mem_count += instances[:gpu] * gpu_instance[:mem] * 1000.0 # convert GB to MB
    end

    compute_instance = Instance::AWS_INSTANCES[:compute][:base]
    mem_instance = Instance::AWS_INSTANCES[:mem][:base]
    while cpu_count < cpus || mem_count < mem
      to_add = :compute
      if mem_count < mem
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
    end
    instances
  end

  def best_fit_instances(instance_numbers, nodes)
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

    if instance_numbers[:gpu] > 0
      instances << best_fit_for_type(:gpu, instance_numbers[:gpu], nodes)
      instances.flatten!

      instance_numbers = recalculate_instance_numbers(instances)
      nodes = nodes - instances.length
    end

    if instance_numbers[:mem] > 0
      instances << best_fit_for_type(:mem, instance_numbers[:mem], nodes)
      instances.flatten!

      instance_numbers = recalculate_instance_numbers(instances)
      nodes = nodes - instances.length
    end

    if instance_numbers[:compute] > 0
      instances << best_fit_for_type(:compute, instance_numbers[:compute], nodes)
      instances.flatten!
    end

    instances
  end

  def best_fit_for_type(type, target, nodes)
    original_nodes = nodes.clone
    instances = []
    count = 0
    multipliers = Instance::AWS_INSTANCES[type][:multipliers]
    while count < target && nodes > 0
      best_fit = nil
      per_node = (target - count) / nodes
      multipliers.each do |m|
        if m == per_node || m > per_node
          best_fit = m
          break
        end
      end
      best_fit ||= multipliers.last
      instances << Instance.new(type, best_fit)
      count += best_fit
      nodes -= 1
    end
    
    # if can't meet needs in number of nodes, increase node count by one and try again
    if count < target
      return best_fit_for_type(type, target, (original_nodes + 1))
    end
    instances
  end

  def recalculate_instance_numbers(instances)
    new_total_mem = 0.0
    new_total_cpus = 0
    instances.each do |i|
      new_total_mem += (i.mem * 1000)
      new_total_cpus += i.cpus
    end
    required_mem = [(@total_mem - new_total_mem), 0.0].max
    required_cpus = [(@total_cpus - new_total_cpus), 0].max
    base_instance_numbers(required_cpus, 0, required_mem)
  end
end
