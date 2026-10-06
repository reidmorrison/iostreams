module IOStreams
  # Build the streams that need to be applied to a path during reading or writing.
  class Builder
    attr_accessor :file_name
    attr_reader :streams, :options

    def initialize(file_name = nil)
      @file_name = file_name
      @streams   = nil
      @options   = nil
    end

    # A copy has its own streams and options, so that changing them does not change the original.
    def initialize_copy(source)
      super
      @streams = @streams&.transform_values(&:dup)
      @options = @options&.transform_values(&:dup)
    end

    # Supply an option that is only applied once the file name extensions have been parsed.
    # Note:
    # - Cannot set both `stream` and `option`
    # - Raises ArgumentError for an option that neither the reader nor the writer for the stream accepts,
    #   even when the file name does not include the stream.
    def option(stream, **options)
      stream = stream.to_sym unless stream.is_a?(Symbol)
      raise(ArgumentError, "Invalid stream: #{stream.inspect}") unless IOStreams.extensions.include?(stream)
      raise(ArgumentError, "Cannot call both #option and #stream on the same streams instance") if @streams
      raise(ArgumentError, "Cannot call #option unless the `file_name` was already set") unless file_name

      reject_unknown_options(stream, options)
      @options ||= {}
      if (opts = @options[stream])
        opts.merge!(options)
      else
        @options[stream] = options.dup
      end
      self
    end

    def stream(stream, **options)
      stream = stream.to_sym unless stream.is_a?(Symbol)
      raise(ArgumentError, "Cannot call both #option and #stream on the same streams instance") if @options

      # To prevent any streams from being applied supply a stream named `:none`
      if stream == :none
        @streams = {}
        return self
      end
      raise(ArgumentError, "Invalid stream: #{stream.inspect}") unless IOStreams.extensions.include?(stream)

      reject_unknown_options(stream, options)
      @streams ||= {}
      if (opts = @streams[stream])
        opts.merge!(options)
      else
        @streams[stream] = options.dup
      end
      self
    end

    def option_or_stream(stream, **)
      if streams
        stream(stream, **)
      elsif file_name
        option(stream, **)
      else
        stream(stream, **)
      end
    end

    # Return the options set for either a stream or option.
    def setting(stream)
      return streams[stream] if streams

      options[stream] if options
    end

    def reader(io_stream, &)
      execute(:reader, pipeline, io_stream, &)
    end

    def writer(io_stream, &)
      execute(:writer, pipeline, io_stream, &)
    end

    # Returns [Hash<Symbol:Hash>] the pipeline of streams
    # with their options that will be applied when the reader or writer is invoked.
    def pipeline
      return streams.dup.freeze if streams

      build_pipeline.freeze
    end

    # Removes the named stream from the current pipeline.
    # If the stream pipeline has not yet been built it will be built from the file_name if present.
    # Note: Any options must be set _before_ calling this method.
    def remove_from_pipeline(stream_name)
      @streams ||= build_pipeline
      @streams.delete(stream_name.to_sym)
    end

    # Returns [true|false] whether a stream in the pipeline compresses the data.
    # Each stream's format answers for itself, see `IOStreams.register_extension`.
    def compressed?
      pipeline.each_key.any? { |stream| stream_format(stream).compressed? }
    end

    # Returns [true|false] whether a stream in the pipeline encrypts the data.
    # Each stream's format answers for itself, see `IOStreams.register_extension`.
    def encrypted?
      pipeline.each_key.any? { |stream| stream_format(stream).encrypted? }
    end

    private

    def build_pipeline
      return {} unless file_name

      built_streams          = {}
      # Encode stream is always first
      built_streams[:encode] = options[:encode] if options&.key?(:encode)

      opts = options || {}
      parse_extensions.each { |stream| built_streams[stream] = opts[stream] || {} }
      built_streams
    end

    # Returns the format registered for the stream, see `IOStreams.register_extension`.
    def stream_format(stream)
      IOStreams.extensions[stream&.to_sym] || raise(ArgumentError, "Unknown Stream type: #{stream.inspect}")
    end

    def class_for_stream(type, stream)
      stream_format(stream).send("#{type}_class") ||
        raise(ArgumentError, "No #{type} registered for Stream type: #{stream.inspect}")
    end

    # Returns the streams for the supplied file_name
    def parse_extensions
      parts      = Utils.file_name_extensions(file_name)
      extensions = []
      while (extension = parts.pop)
        sym = extension.to_sym
        break unless IOStreams.extensions[sym]

        extensions.unshift(sym)
      end
      extensions
    end

    # Executes the streams that need to be executed.
    def execute(type, pipeline, io_stream, &block)
      raise(ArgumentError, "IOStreams call is missing mandatory block") if block.nil?

      if pipeline.empty?
        block.call(io_stream)
      elsif pipeline.size == 1
        stream, opts = pipeline.first
        open_stream(type, stream, io_stream, opts, &block)
      else
        # Daisy chain multiple streams together
        last = pipeline.keys.inject(block) do |inner, stream_sym|
          ->(io) { open_stream(type, stream_sym, io, pipeline[stream_sym], &inner) }
        end
        last.call(io_stream)
      end
    end

    def open_stream(type, stream, io_stream, opts, &)
      klass = class_for_stream(type, stream)
      validate_options(type, stream, opts)
      # Pass only the options that the stream uses, leaving out those that are valid but that it does not need,
      # such as `compress` when reading `.enc`.
      accepted = stream_format(stream).option_names(type)
      opts     = opts.slice(*accepted) if accepted
      # A stream can default its options from the file name, such as the name of the file within a zip file.
      opts = klass.file_name_options(file_name, **opts) if file_name && klass.respond_to?(:file_name_options)
      klass.open(io_stream, **opts, &)
    end

    # Options are strict: an option that is not valid for the stream raises instead of being ignored.
    # The stream's format decides which options are valid, see `IOStreams::StreamFormat#valid_option_names`,
    # and the message names the direction that an option is only valid for.
    def validate_options(type, stream, opts)
      valid = stream_format(stream).valid_option_names(type)
      return if valid.nil?

      unknown = opts.keys - valid
      return if unknown.empty?

      other_names = stream_format(stream).option_names(type == :reader ? :writer : :reader) || []
      other_only  = unknown & other_names
      invalid     = unknown - other_names
      direction   = type == :reader ? "reading" : "writing"

      messages = []
      if other_only.any?
        messages << "#{list(other_only)} only #{other_only.size == 1 ? 'applies' : 'apply'} when " \
                    "#{type == :reader ? 'writing' : 'reading'} a #{stream.inspect} stream and cannot be used when " \
                    "#{direction}. Configure a separate path or stream without #{other_only.size == 1 ? 'it' : 'them'} " \
                    "for #{direction}."
      end
      if invalid.any?
        messages << "Unknown #{invalid.size == 1 ? 'option' : 'options'} #{list(invalid)} when #{direction} " \
                    "a #{stream.inspect} stream. Valid options: #{list(valid)}."
      end
      raise(ArgumentError, messages.join(" "))
    end

    # Options are checked when they are set, against the options that are valid when either reading or
    # writing the stream, since it is not yet known which will be used. So a misspelled option raises wherever
    # the code runs, even when the file name does not include the stream, rather than only where the path,
    # for example from configuration, includes it.
    def reject_unknown_options(stream, options)
      valid = stream_format(stream).valid_option_names
      return if valid.nil?

      unknown = options.keys - valid
      return if unknown.empty?

      raise(ArgumentError, "Unknown #{unknown.size == 1 ? 'option' : 'options'} #{list(unknown)} for a " \
                           "#{stream.inspect} stream. Valid options: #{list(valid)}.")
    end

    def list(names)
      names.empty? ? "none" : names.map(&:inspect).join(", ")
    end
  end
end
