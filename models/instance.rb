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
    @base_mem * @multiplier # in GB
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
