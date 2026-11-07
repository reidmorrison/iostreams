# frozen_string_literal: true

# Finds the state of IOStreams that only the main Ractor can read: the constants, and the instance variables of its
# classes and modules, whose values are not shareable, see `Ractor.shareable?`. It loads every constant, so a test runs
# it in a process of its own, see test/shareable_test.rb, since the other tests rely on loading the gems of the formats
# only when a format is used. Require it before IOStreams, so that it records the names of their private constants,
# which Ruby does not list, see .private_constants.
module ShareableState
  if $LOADED_FEATURES.any? { |feature| feature.end_with?("/iostreams.rb") }
    raise(LoadError, "Require shareable_state before iostreams, so that it finds the private constants of IOStreams")
  end

  # Records the names of the private constants of each module as it declares them, see .private_constants.
  module RecordPrivateConstants
    def private_constant(*names)
      ShareableState.private_constants[self].concat(names.map(&:to_sym))
      super
    end
  end

  @private_constants = Hash.new { |names, mod| names[mod] = [] }
  ::Module.prepend(RecordPrivateConstants)

  # Returns [Hash<Module, Array<Symbol>>] the names of the private constants of each module, since `Module#constants`
  # lists only the public ones.
  def self.private_constants
    @private_constants
  end

  # Returns [Array<Module>] the supplied module and the modules and classes within it, loading every constant within
  # them, autoloads included, apart from the modules named in `except`, and the constants whose file cannot be loaded on
  # this platform, such as the zstd-jni stream of JRuby.
  def self.modules(root, except: [])
    found = {}
    walk  = lambda do |mod|
      next if found.key?(mod) || except.include?(mod.name)

      found[mod] = true
      names(mod).each do |name|
        value = constant(mod, name)
        walk.call(value) if value.is_a?(Module) && value.name&.start_with?("#{root.name}::")
      end
    end
    walk.call(root)
    found.keys
  end

  # Returns [Array<String>] the name of each constant of the supplied modules whose value is not shareable.
  def self.unshareable_constants(modules)
    modules.flat_map do |mod|
      names(mod).filter_map do |name|
        value = constant(mod, name)
        "#{mod.name}::#{name}" unless value.is_a?(Module) || Ractor.shareable?(value)
      end
    end
  end

  # Returns [Array<String>] each instance variable of the supplied modules whose value is not shareable, such as
  # "IOStreams::Tabular @formats (Hash)", apart from a Mutex, which only the methods that configure IOStreams lock, in
  # the main Ractor.
  def self.unshareable_class_state(modules)
    modules.flat_map do |mod|
      mod.instance_variables.filter_map do |name|
        value = mod.instance_variable_get(name)
        "#{mod.name} #{name} (#{value.class})" unless value.is_a?(Thread::Mutex) || Ractor.shareable?(value)
      end
    end
  end

  # Returns [Array<Symbol>] the names of the public and private constants of the module.
  def self.names(mod)
    mod.constants(false) | private_constants.fetch(mod, [])
  end
  private_class_method :names

  # Returns the value of the constant, loading its file, or nil when that file cannot be loaded on this platform.
  def self.constant(mod, name)
    mod.const_get(name, false)
  rescue LoadError
    nil
  end
  private_class_method :constant
end
