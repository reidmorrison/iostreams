module IOStreams
  # The options of a format registered with `IOStreams.register_extension`, such as `IOStreams::Gzip`,
  # which come from its reader and writer classes.
  #
  # A format extends this module, and answers `reader_class` and `writer_class`.
  #
  # One option hash is shared by a stream's reader and writer, so that the same path can be written and then
  # read. So by default the options of the other direction are also valid, and are ignored, such as `compress`
  # when reading `.enc`, whose header records it. A class can exclude an option of the other direction by
  # overriding its `valid_option_names`, so that it raises, with a message that names the direction it
  # belongs to.
  module StreamFormat
    # Returns [Array<Symbol>] the options that the class reading (type: :reader) or writing (:writer) this
    # format uses, which are the only options supplied to it, or [nil] when the class does not declare them.
    def option_names(type)
      klass = stream_class(type)
      klass.option_names if klass.respond_to?(:option_names)
    end

    # Returns [Array<Symbol>] the options that are valid when reading (type: :reader) or writing (:writer)
    # this format, or when either (nil), or [nil] when they are not checked, since a class does not declare
    # its options, which a class registered via `IOStreams.register_extension` need not.
    #
    # Unless the class overrides `valid_option_names`, they are its own options and those of the class for
    # the other direction. When that class does not declare its options, only the class's own are valid.
    def valid_option_names(type = nil)
      return valid_option_names_for_either if type.nil?

      klass    = stream_class(type)
      declared = klass.valid_option_names if klass.respond_to?(:valid_option_names)
      return declared if declared

      own = option_names(type)
      return if own.nil?

      own | (option_names(type == :reader ? :writer : :reader) || [])
    end

    private

    # Options are checked when they are set, against those that are valid when either reading or writing,
    # since it is not yet known which will be used. Not checked when the reader or the writer does not
    # declare its options.
    def valid_option_names_for_either
      types = %i[reader writer].select { |type| stream_class(type) }
      names = types.map { |type| valid_option_names(type) }
      return if names.empty? || names.include?(nil)

      valid = names.flatten
      # The reader's options and then the writer's, in the order that they declare them.
      (types.flat_map { |type| option_names(type) || [] } + valid).uniq & valid
    end

    def stream_class(type)
      case type
      when :reader
        reader_class
      when :writer
        writer_class
      else
        raise(ArgumentError, "Invalid type: #{type.inspect}. Valid types: :reader, :writer.")
      end
    end
  end
end
