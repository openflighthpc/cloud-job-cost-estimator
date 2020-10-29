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

  AWS_INSTANCES = YAML.load(File.read("aws_instances.yml"))

  def initialize(type, multiplier = 1)
    raise ArgumentError, 'Not a valid instance type' if !AWS_INSTANCES.keys.include?(type.to_sym)
    raise ArgumentError, 'Not a valid multiplier for that type' if !AWS_INSTANCES[type.to_sym][:multipliers].include?(multiplier)
    @type = type.to_sym
    @multiplier = multiplier
    @base_cpus = AWS_INSTANCES[@type][:base][:cpus]
    @base_gpus = AWS_INSTANCES[@type][:base][:gpus]
    @base_mem = AWS_INSTANCES[@type][:base][:mem]
    @base_price_per_min = BigDecimal(AWS_INSTANCES[@type][:base][:price_per_min], 8)
    @base_name = AWS_INSTANCES[@type][:base][:name]
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
    AWS_INSTANCES[@type][:multipliers].sort
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
