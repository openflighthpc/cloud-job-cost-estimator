require_relative 'instance'

class InstanceCalculator
  attr_reader :base_instance, :base_instance_count
  attr_reader :best_fit_instance, :best_fit_count
  attr_reader :any_nodes_instance, :any_nodes_count

  def initialize(total_cpus, total_gpus, total_mem, total_nodes, time, include_any_nodes=true)
    @total_cpus = total_cpus
    @total_gpus = total_gpus
    @total_mem = total_mem.to_f # in MB
    @total_nodes = total_nodes
    @time = time # in mins
    @base_instance, @base_instance_count = calculate_base_instance_numbers
    @best_fit_instance, @best_fit_count = calculate_best_fit_instances
    @any_nodes_instance, @any_nodes_count = calculate_best_fit_instances(false) if include_any_nodes
  end

  def base_instance_type
    @base_instance.type
  end

  def base_instances_description
    "#{@base_instance_count} #{@base_instance.name}"
  end

  def base_cost_per_min
    @base_instance.cost_per_min * @base_instance_count
  end

  def total_base_cost
    base_cost_per_min * @time
  end

  def best_fit_description
    "#{@best_fit_count} #{@best_fit_instance.name}"
  end

  def best_fit_cost_per_min
    @best_fit_instance.cost_per_min * @best_fit_count
  end

  def total_best_fit_cost
    best_fit_cost_per_min * @time
  end

  def any_nodes_description
    return if !@any_nodes_instance

    "#{@any_nodes_count} #{@any_nodes_instance.name}"
  end

  def any_nodes_cost_per_min
    return if !@any_nodes_instance

    @any_nodes_instance.cost_per_min * @any_nodes_count
  end

  def total_any_nodes_cost
    return if !@any_nodes_instance

    any_nodes_cost_per_min * @time
  end

  def any_nodes_is_different?
    return if !@any_nodes_instance

    @any_nodes_instance != @best_fit_instance
  end

  private

  # Determine which of the three instance types is most appropriate
  # and how many of the 'base' (smallest) instance are required.
  def calculate_base_instance_numbers
    instance = nil
    instance_count = 0
    gpu_count = 0
    cpu_count = 0
    mem_count = 0

    # Gpus are priority, as can only be given by gpu instances.
    # Additionally, gpu instances have high core counts and memory.
    if @total_gpus > 0
      instance = Instance.new(:gpu) 
    else
      # A compute instance has 2GB per 1 core. If need more than this, use a mem instance,
      # which has 8GB per cpu.
      mem_per_cpu = @total_mem / @total_cpus
      base_instance_type = mem_per_cpu > 2000 ? :mem : :compute
      instance = Instance.new(base_instance_type)
    end

    while gpu_count < @total_gpus || cpu_count < @total_cpus || mem_count < @total_mem
      instance_count += 1
      gpu_count += instance.gpus
      cpu_count += instance.cpus
      mem_count += instance.mem * 1000 # convert GB to MB
    end
    
    return instance, instance_count
  end

  def calculate_best_fit_instances(consider_nodes=true)
    nodes = consider_nodes ? @total_nodes.clone : 1 # if ignoring actual nodes, start with fewest possible and work up
    count = 0.0
    target = base_instance_count
    multipliers = @base_instance.possible_multipliers
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
      # if needs less than that of base.
      best_fit = multipliers.first if per_node < multipliers.first
      count += best_fit
      
      # If can't meet needs in one node, increase node count by one and continue.
      if count < target
        nodes = 2
        count = 0.0
      else
        return Instance.new(base_instance_type, best_fit.to_i), 1
      end
    end
    
    best_fit = nil
    while !best_fit
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

    return Instance.new(base_instance_type, best_fit.to_i), nodes
  end
end
