# frozen_string_literal: true

require "prism"

# Finds the class-level methods of Ruby files that set an instance variable of their class or module, or change the
# value of one in place, other than in the branch of an `if IOStreams::Utils.main_ractor?`, since a Ractor other than
# the main Ractor can never set them, see test/shareable_test.rb: an assignment, `instance_variable_set` on the class
# itself, a class-level writer of these files called with `send` on it or another class, such as a subclass, and the
# writers that `attr_writer`
# and `attr_accessor` define on it. `instance_variable_set` on another object is not counted, since it is how a class
# method builds an instance, such as one that it allocates. A block of a Proc or a method that a class method defines
# runs on another object, so the instance variables within it are not those of the class.
class ClassStateWriters < Prism::Visitor
  # The methods that change a Hash or an Array in place.
  MUTATORS = %i[[]= << delete store push concat clear update merge! replace shift pop unshift insert delete_if keep_if
                compact! uniq! reject! select! filter! transform_values! transform_keys!].freeze

  # The methods whose block runs on another object than the class.
  OTHER_SELF = %i[proc lambda define_method define_singleton_method instance_exec instance_eval].freeze

  # The methods that define a writer of an instance variable.
  ATTR_WRITERS = %i[attr_writer attr_accessor].freeze

  # The methods that call another, such as a writer.
  SENDERS = %i[send public_send __send__].freeze

  # Returns [Array<String>] the methods that do, such as "IOStreams.add_root", in the supplied files.
  def self.find(files)
    finders = files.map { |file| new.tap { |finder| Prism.parse_file(file).value.accept(finder) } }
    # A writer sent to an object is that of a class when one of the files defines it as a class-level method.
    class_methods = finders.flat_map(&:class_methods)
    sent          = finders.flat_map(&:sent).filter_map { |method, writer| method if class_methods.include?(writer) }
    (finders.flat_map(&:writers) + sent).uniq.sort
  end

  attr_reader :writers, :class_methods, :sent

  def initialize
    super
    @writers       = []
    @class_methods = []
    @sent          = []
    @namespace     = []
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
    @class_methods << node.name if class_level
    in_method(class_level ? "#{@namespace.join('::')}.#{node.name}" : nil) { super }
  end

  # Only the branch of `if Utils.main_ractor?` is guarded, not its else, nor that of a negated condition.
  def visit_if_node(node)
    predicate = node.predicate
    return super unless predicate.is_a?(Prism::CallNode) && predicate.name == :main_ractor?

    visit(predicate)
    guarded { visit(node.statements) }
    visit(node.respond_to?(:subsequent) ? node.subsequent : node.consequent)
  end

  def visit_lambda_node(node)
    in_method(nil) { super }
  end

  def visit_call_node(node)
    record if ivar?(node.receiver) && (MUTATORS.include?(node.name) || node.attribute_write?)
    record if node.name == :instance_variable_set && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
    @sent << [@method, node.arguments.arguments.first.unescaped.to_sym] if sends_writer?(node) && @method && @guarded.zero?
    record_attr_writers(node) if ATTR_WRITERS.include?(node.name) && class_level_attr?(node)
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

  def guarded
    @guarded += 1
    yield
  ensure
    @guarded -= 1
  end

  # Returns [true|false] whether the call sends a writer, such as `contract.send(:descriptor=, value)`.
  def sends_writer?(node)
    name = node.arguments&.arguments&.first
    SENDERS.include?(node.name) && name.is_a?(Prism::SymbolNode) && name.unescaped.end_with?("=")
  end

  # Returns [true|false] whether `attr_writer` or `attr_accessor` defines its writers on a class, within
  # `class << self`, or on `singleton_class`.
  def class_level_attr?(node)
    return @singleton.positive? && @method.nil? if node.receiver.nil?

    node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :singleton_class
  end

  # Records the writer of each name of an `attr_writer` or `attr_accessor` on a class.
  def record_attr_writers(node)
    node.arguments&.arguments&.each do |name|
      next unless name.is_a?(Prism::SymbolNode) || name.is_a?(Prism::StringNode)

      @writers << "#{@namespace.join('::')}.#{name.unescaped}="
    end
  end

  def record
    @writers << @method if @method && @guarded.zero?
  end
end
