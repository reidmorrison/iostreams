module IOStreams
  module Deprecation
    # A module whose methods report a deprecation warning when the application calls them, and then call the method of
    # the object that it extends, see .deprecate: for the methods of an object that IOStreams hands the application, such
    # as the `Zlib::GzipReader` that a reader block receives for a `.gz` file, that the object that v3.0 hands it in its
    # place does not answer, such as `#rewind`.
    class Methods < ::Module
      @modules = {}
      @mutex   = Mutex.new

      # Extends the supplied object, which IOStreams hands to the application, with a module that reports a deprecation
      # warning for each of its public methods that the object in its place in v3.0 does not answer: those other than
      # the supplied methods, which that object answers, and the methods of every object. Each warning is the name of the
      # method, such as `#rewind`, followed by the supplied message, such as "is deprecated on ...", or by the message of
      # its name when the message is a Hash, such as one that names what replaces it, otherwise that of nil.
      #
      # The module is prepended to the singleton class of the object, rather than extending it, so that its methods
      # come before those that the object defines on itself, such as the `#path` of a `Zlib::GzipReader`. The object
      # keeps its class, and answers the same methods, which each still call its own method. Only the calls that the
      # application makes itself report a warning, see `IOStreams::Deprecation.warn_call`, and none while deprecation
      # warnings are off. The module is built once for each class of object, and kept, so that each object costs one
      # `prepend`, and nothing else until a deprecated method is called.
      #
      # Returns the object.
      def self.deprecate(object, kept_methods, message)
        return object if object.frozen?

        key        = [object.class, object.singleton_methods.sort, kept_methods, message]
        deprecated = @mutex.synchronize do
          @modules[key] ||= new(object.public_methods - ::Object.public_instance_methods - kept_methods, message)
        end
        object.singleton_class.prepend(deprecated)
        object
      end

      # Defines a method for each of the supplied names that reports the deprecation warning of its name, followed by the
      # supplied message, or its own message when it is a Hash, see .deprecate, when the application calls it, and then
      # calls the method of the object.
      def initialize(names, message)
        super()
        names.each do |name|
          warning = "##{name} #{message.is_a?(Hash) ? message.fetch(name) { message.fetch(nil) } : message}".freeze
          define_method(name) do |*args, **kwargs, &block|
            ::IOStreams::Deprecation.warn_call(warning) if ::Warning[:deprecated]
            super(*args, **kwargs, &block)
          end
        end
      end
    end
  end
end
