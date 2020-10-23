class Instance
  attr_reader :type

  AWS_INSTANCES = {
    gpu: { 
      base: { 
        name: "p3.2xlarge", cpus: 8, gpus: 1, mem: 61, price_per_min: 0.05982
      },
      multipliers: [1, 4, 8]
    },
    compute: {
      base: {
        name: "c5.large", cpus: 2, mem: 4, gpus: 0, price_per_min: 0.00168
      },
      multipliers: [1, 2, 4, 8, 13, 24, 32, 48]
    },
    mem: {
      base: {
        name: "r5.large", cpus: 2, mem: 16, gpus: 0, price_per_min: 0.00246
      },
      multipliers: [1, 2, 4, 8, 16, 24, 48]
    }
  }

  def self.base_instance_numbers(cpus, gpus, mem)
    @@cpus = cpus
    @@gpus = gpus
    @@mem = mem.to_f # in MB

    instances = {gpu: 0, compute: 0, mem: 0}
    cpu_count = 0
    mem_count = 0
    # gpus are priority, as can only be given by gpu instances.
    # Additionally, gpu instances have high core counts and memory.
    if gpus > 0
      gpu_instance = AWS_INSTANCES[:gpu][:base]
      gpu_count = 0
      while gpu_count < gpus
        instances[:gpu] += 1
        gpu_count += gpu_instance[:gpus]
      end
      cpu_count += instances[:gpu] * gpu_instance[:cpus]
      mem_count += instances[:gpu] * gpu_instance[:mem] * 1000.0 # convert GB to MB
    end

    compute_instance = AWS_INSTANCES[:compute][:base]
    mem_instance = AWS_INSTANCES[:mem][:base]
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
      cpu_count += AWS_INSTANCES[to_add][:base][:cpus]
      mem_count += AWS_INSTANCES[to_add][:base][:mem] * 1000 # GB to MB
    end
    instances
  end

  def self.best_fit_instances(instance_numbers, nodes)
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

  def self.best_fit_for_type(type, target, nodes)
    instances = []
    count = 0
    multipliers = AWS_INSTANCES[type][:multipliers]
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
    instances
  end

  def self.recalculate_instance_numbers(instances)
    new_total_mem = 0.0
    new_total_cpus = 0
    instances.each do |i|
      new_total_mem = i.mem * 1000
      new_total_cpus = i.cpus
    end
    required_mem = [(@@mem - new_total_mem), 0.0].max
    required_cpus = [(@@cpus - new_total_cpus), 0].max
    base_instance_numbers(required_cpus, 0, required_mem)
  end

  def initialize(type, multiplier = 1)
    raise ArgumentError, 'Not a valid instance type' if !AWS_INSTANCES.keys.include?(type.to_sym)
    raise ArgumentError, 'Not a valid multiplier for that type' if multiplier != 1 && !AWS_INSTANCES[type.to_sym][:multipliers].include?(multiplier)
    @type = type.to_sym
    @multiplier = multiplier
    @base_cpus = AWS_INSTANCES[@type][:base][:cpus]
    @base_gpus = AWS_INSTANCES[@type][:base][:gpus]
    @base_mem = AWS_INSTANCES[@type][:base][:mem]
    @base_price_per_min = AWS_INSTANCES[@type][:base][:price_per_min]
    @base_name = AWS_INSTANCES[@type][:base][:name]
  end

  def cpus
    @base_cpus * @multiplier
  end

  def gpus
    @base_gpus * @multiplier
  end

  def mem
    @base_mem * @multiplier
  end

  def price_per_min
    @base_price_per_min * @multiplier
  end

  def update_multiplier(multiplier)
    if multiplier != 1 && !AWS_INSTANCES[@type][:multipliers].include?(multiplier)
      puts "invalid multiplier for this instance type"
    else
      @multiplier = multiplier
    end
  end

  def name
    if @multiplier == 1
      @base_name
    else
      if type == :gpu
        @base_name.gsub("2", (2 * @multiplier).to_s)
      else
        number_of_xs = @multiplier / 2
        number_of_xs = nil if number_of_xs == 1
        @base_name.gsub(".", ".#{number_of_xs}x")
      end
    end
  end
end
