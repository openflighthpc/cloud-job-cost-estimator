require 'yaml'

class Instance
  attr_reader :type

  AWS_INSTANCES = YAML.load(File.read("aws_instances.yml"))

  def initialize(type, multiplier = 1)
    raise ArgumentError, 'Not a valid instance type' if !AWS_INSTANCES.keys.include?(type.to_sym)
    raise ArgumentError, 'Not a valid multiplier for that type' if !AWS_INSTANCES[type.to_sym][:multipliers].include?(multiplier)
    @type = type.to_sym
    @multiplier = multiplier.to_i
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
