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

require_relative 'instance'

class InstanceCalculator
  @@grouped_best_fit = {}
  @@grouped_best_fit_description = nil

  attr_reader :base_instance, :base_instance_count
  attr_reader :best_fit_instance, :best_fit_count
  attr_reader :any_nodes_instance, :any_nodes_count

  def self.grouped_best_fit
    @@grouped_best_fit
  end

  def self.grouped_best_fit_description
    return @@grouped_best_fit_description if @@grouped_best_fit_description
    
    sorted_instances = @@grouped_best_fit.keys.sort_by do |key|
      [
        key.split(" ")[1].split(".")[0],
        key.split(".")[1].split("x")[0].to_i,
        key.split(".")[1],
        key.split(" ")[0].to_i
      ]
    end
      
    @@grouped_best_fit_description = ""
    sorted_instances.each do |instance_and_number|
      group = @@grouped_best_fit[instance_and_number]
      @@grouped_best_fit_description <<  "#{group[:jobs]} job(s) can be run on #{instance_and_number}. "
      @@grouped_best_fit_description << "At a total time of #{group[:time]}mins this would cost $#{group[:cost].to_f.ceil(2)}.\n"  
    end

    @@grouped_best_fit_description
  end

   def initialize(total_cpus, total_gpus, total_mem, total_nodes, time, include_any_nodes=true, customer_facing=false)
    @total_cpus = total_cpus
    @total_gpus = total_gpus
    @total_mem = total_mem.to_f # in MB
    @total_nodes = total_nodes
    @time = time # in mins
    @customer_facing = customer_facing
    @base_instance, @base_instance_count = calculate_base_instance_numbers
    @best_fit_instance, @best_fit_count = calculate_best_fit_instances
    @any_nodes_instance, @any_nodes_count = calculate_best_fit_instances(false) if include_any_nodes
    update_best_fit_grouping
  end

  def base_instance_type
    @base_instance.type
  end

  def base_instance_name
    @customer_facing ? @base_instance.customer_facing_name : @base_instance.name
  end

  def base_instances_description
    "#{@base_instance_count} #{base_instance_name}"
  end

  def base_cost_per_min
    @base_instance.cost_per_min * @base_instance_count
  end

  def total_base_cost
    base_cost_per_min * @time
  end

  def best_fit_name
    @customer_facing ? @best_fit_instance.customer_facing_name : @best_fit_instance.name
  end

  def best_fit_description
    "#{@best_fit_count} #{best_fit_name}"
  end

  def best_fit_cost_per_min
    @best_fit_instance.cost_per_min * @best_fit_count
  end

  def total_best_fit_cost
    best_fit_cost_per_min * @time
  end

  def any_nodes_name
    return if !@any_nodes_instance

    @customer_facing ? @any_nodes_instance.customer_facing_name : @any_nodes_instance.name
  end

  def any_nodes_description
    return if !@any_nodes_instance

    "#{@any_nodes_count} #{any_nodes_name}"
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

  def any_nodes_best_fit_cost_diff
    return if !@any_nodes_instance

    total_best_fit_cost - total_any_nodes_cost
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
    # Additionally, gpu instances have high cpu counts and memory.
    if @total_gpus > 0
      instance = Instance.new(:gpu) 
    else
      # A compute instance has 2GB per 1 cpu. If need more than this, use a mem instance,
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
    target = base_instance_count.to_f
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
      else
        return Instance.new(base_instance_type, best_fit.to_i), 1
      end
    end
    
    best_fit = nil
    while !best_fit
      per_node = target / nodes
      if multipliers.include?(per_node)
        best_fit = per_node
      elsif per_node < multipliers.first
        best_fit = multipliers.first
      else
        nodes += 1
      end
    end

    return Instance.new(base_instance_type, best_fit.to_i), nodes
  end

  def update_best_fit_grouping
    if @@grouped_best_fit.has_key?(best_fit_description)
      @@grouped_best_fit[best_fit_description][:cost] = @@grouped_best_fit[best_fit_description][:cost] + total_best_fit_cost
      @@grouped_best_fit[best_fit_description][:time] = @@grouped_best_fit[best_fit_description][:time] + @time
      @@grouped_best_fit[best_fit_description][:jobs] = @@grouped_best_fit[best_fit_description][:jobs] += 1
    else
      @@grouped_best_fit[best_fit_description] = {cost: total_best_fit_cost, time: @time, jobs: 1}
    end
  end
end
