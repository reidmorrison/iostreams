# frozen_string_literal: true

require "prism"

# Finds the class-level methods of Ruby files that set an instance variable of their class or module, or change the
# value of one in place, other than under `IOStreams::Utils.main_ractor?`, since a Ractor other than the main Ractor can
# never set them, see test/shareable_test.rb. A block of a Proc or a method that a class method defines runs on another
# object, so the instance variables within it are not those of the class.
class ClassStateWriters < Prism::Visitor
  # The methods that change a Hash or an Array in place.
  MUTATORS = %i[[]= << delete store push concat clear update merge! replace shift pop unshift insert delete_if keep_if
                compact! uniq! reject! select! filter! transform_values! transform_keys!].freeze

  # The methods whose block runs on another object than the class.
  OTHER_SELF = %i[proc lambda define_method define_singleton_method instance_exec instance_eval].freeze

  # Returns [Array<String>] the methods that do, such as "IOStreams.add_root", in the supplied files.
  def self.find(files)
    files.flat_map do |file|
      finder = new
      Prism.parse_file(file).value.accept(finder)
      finder.writers
    end.uniq.sort
  end

  attr_reader :writers

  def initialize
    super
    @writers   = []
    @namespace = []
    @singleton = 0
    @guarded   = 0
    @method    = nil
  end

  def visit_module_node(node)
    within(node.constant_path.slice) { super }
  end

  def visit_class_node(node)
    within(node.constant_path.slice) { super }
  end

  def visit_singleton_class_node(node)
    @singleton += 1
    super
  ensure
    @singleton -= 1
  end

  def visit_def_node(node)
    class_level = node.receiver.is_a?(Prism::SelfNode) || @singleton.positive?
    in_method(class_level ? "#{@namespace.join('::')}.#{node.name}" : nil) { super }
  end

  def visit_if_node(node)
    guarded = node.predicate.slice.include?("main_ractor?")
    @guarded += 1 if guarded
    super
  ensure
    @guarded -= 1 if guarded
  end

  def visit_lambda_node(node)
    in_method(nil) { super }
  end

  def visit_call_node(node)
    record if ivar?(node.receiver) && (MUTATORS.include?(node.name) || node.attribute_write?)
    return super unless OTHER_SELF.include?(node.name)

    in_method(nil) { super }
  end

  %i[instance_variable_write_node instance_variable_or_write_node instance_variable_and_write_node
     instance_variable_operator_write_node].each do |type|
    define_method(:"visit_#{type}") do |node|
      record
      super(node)
    end
  end

  # Such as `@cache[key] ||= value` or `@settings.name += 1`, which change the value of the instance variable.
  %i[index_or_write_node index_and_write_node index_operator_write_node call_or_write_node call_and_write_node
     call_operator_write_node].each do |type|
    define_method(:"visit_#{type}") do |node|
      record if ivar?(node.receiver)
      super(node)
    end
  end

  private

  def within(name)
    @namespace.push(name)
    yield
  ensure
    @namespace.pop
  end

  def in_method(name)
    outer   = @method
    @method = name
    yield
  ensure
    @method = outer
  end

  def ivar?(node)
    node.is_a?(Prism::InstanceVariableReadNode)
  end

  def record
    @writers << @method if @method && @guarded.zero?
  end
end
