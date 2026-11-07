# frozen_string_literal: true

# Finds the state of IOStreams that only the main Ractor can read: the constants whose values are not shareable, see
# `Ractor.shareable?`. It loads every constant, so a test runs it in a process of its own, see test/shareable_test.rb,
# since the other tests rely on loading the gems of the formats only when a format is used.
module ShareableState
  # Returns [Array<Module>] the supplied module and the modules and classes within it, loading every constant within
  # them, autoloads included, apart from the modules named in `except`, and the constants whose file cannot be loaded on
  # this platform, such as the zstd-jni stream of JRuby.
  def self.modules(root, except: [])
    found = {}
    walk  = lambda do |mod|
      next if found.key?(mod) || except.include?(mod.name)

      found[mod] = true
      mod.constants(false).each do |name|
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
      mod.constants(false).filter_map do |name|
        value = constant(mod, name)
        "#{mod.name}::#{name}" unless value.is_a?(Module) || Ractor.shareable?(value)
      end
    end
  end

  # Returns the value of the constant, loading its file, or nil when that file cannot be loaded on this platform.
  def self.constant(mod, name)
    mod.const_get(name, false)
  rescue LoadError
    nil
  end
  private_class_method :constant
end
