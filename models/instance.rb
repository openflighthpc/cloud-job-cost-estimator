#==============================================================================
# Copyright (C) 2020-present Alces Flight Ltd.
#
# This file is part of cloud-job-cost-estimator.
#
# This program and the accompanying materials are made available under
# the terms of the Eclipse Public License 2.0 which is available at
# <https://www.eclipse.org/legal/epl-2.0>, or alternative license
# terms made available by Alces Flight Ltd - please direct inquiries
# about licensing to licensing@alces-flight.com.
#
# cloud-job-cost-estimator is distributed in the hope that it will be useful, but
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, EITHER EXPRESS OR
# IMPLIED INCLUDING, WITHOUT LIMITATION, ANY WARRANTIES OR CONDITIONS
# OF TITLE, NON-INFRINGEMENT, MERCHANTABILITY OR FITNESS FOR A
# PARTICULAR PURPOSE. See the Eclipse Public License 2.0 for more
# details.
#
# You should have received a copy of the Eclipse Public License 2.0
# along with cloud-job-cost-estimator. If not, see:
#
#  https://opensource.org/licenses/EPL-2.0
#
# For more information on cloud-job-cost-estimator, please visit:
# https://github.com/openflighthpc/cloud-job-cost-estimator
#==============================================================================

require 'yaml'
require "bigdecimal"

class Instance
  attr_reader :type, :multiplier

  INSTANCE_OPTIONS = YAML.load(File.read("instance_options.yml"))
  NAMES = %w[small medium large]

  def initialize(type, multiplier = 1, provider=:aws)
    raise ArgumentError, 'Not a valid instance type' if !INSTANCE_OPTIONS[provider].keys.include?(type.to_sym)
    raise ArgumentError, 'Not a valid multiplier for that type' if !INSTANCE_OPTIONS[provider][type.to_sym][:multipliers].include?(multiplier)
    @type = type.to_sym
    @multiplier = multiplier
    @provider = provider
    @base_cpus = INSTANCE_OPTIONS[@provider][@type][:base][:cpus]
    @base_gpus = INSTANCE_OPTIONS[@provider][@type][:base][:gpus]
    @base_mem = INSTANCE_OPTIONS[@provider][@type][:base][:mem]
    @base_price_per_min = BigDecimal(INSTANCE_OPTIONS[@provider][@type][:base][:price_per_min], 8)
    @base_name = INSTANCE_OPTIONS[@provider][@type][:base][:name]
  end

  def ==(other)
    @type == other.type && @multiplier == other.multiplier
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

  def cost_per_min
    @base_price_per_min * @multiplier
  end

  def possible_multipliers
    INSTANCE_OPTIONS[@provider][@type][:multipliers].sort
  end

  def descriptive_type
    type == :gpu ? "GPU" : type.to_s.capitalize
  end

  def customer_facing_name
    relative_size = possible_multipliers.index(@multiplier)
    if relative_size <= 2
      "#{descriptive_type}(#{NAMES[relative_size]})"
    else
      extra = relative_size - 2
      "#{descriptive_type}(#{"x" * extra}large)"
    end
  end

  def name
    if @multiplier == 1
      @base_name
    else
      if @provider == :aws
        if type == :gpu
          @base_name.gsub("2", (2 * @multiplier).to_s)
        else
          number_of_xs = @multiplier / 2
          number_of_xs = nil if number_of_xs == 1
          @base_name.gsub(".", ".#{number_of_xs}x")
        end
      else
        if type == :gpu
          @base_name.sub("6", (6 * @multiplier).to_s)
        else
          @base_name.sub("2", (2 * @multiplier).to_s)
        end
      end
    end
  end
end
