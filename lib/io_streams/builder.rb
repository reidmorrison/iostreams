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
    #   even when the file name does not include the stream. So a misspelled option raises wherever the code
    #   runs, rather than only where the path, for example from configuration, includes the stream.
    def option(stream, **options)
      stream = stream.to_sym unless stream.is_a?(Symbol)
      raise(ArgumentError, "Invalid stream: #{stream.inspect}") unless IOStreams.extensions.include?(stream)
      raise(ArgumentError, "Cannot call both #option and #stream on the same streams instance") if @streams
      raise(ArgumentError, "Cannot call #option unless the `file_name` was already set") unless file_name

      stream_format(stream).validate_options(nil, options, name: stream)
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

      stream_format(stream).validate_options(nil, options, name: stream)
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

    # Yields a stream that reads the supplied stream, which reads the data through this pipeline, as text,
    # for reading lines, rows or records.
    #
    # Text is decoded by the encode stream, see `IOStreams::Encode`. So unless the pipeline already includes it,
    # set with `#option` or `#stream`, the supplied stream is read through the encode stream with its default
    # options, which read UTF-8.
    def text_reader(io_stream, &)
      return yield(io_stream) if pipeline.key?(:encode)

      open_stream(:reader, :encode, io_stream, {}, &)
    end

    # Returns [String] the whole of the data that was read through this pipeline, as text.
    #
    # Like `File.read`, the data is tagged with the default encoding of the encode stream, UTF-8, without checking
    # that it is valid, so that a binary file can be read too, since its bytes are unchanged. The data is returned
    # as it is when the pipeline includes the encode stream, which gave it its encoding, or when the pipeline is
    # empty and the data has an encoding other than binary, which the supplied stream gave it, such as an IO opened
    # with an external encoding.
    def text(data)
      return data if data.nil? || pipeline.key?(:encode)
      return data if pipeline.empty? && data.encoding != Encoding::BINARY

      encoding = stream_format(:encode).default_encoding
      data.frozen? ? data.dup.force_encoding(encoding) : data.force_encoding(encoding)
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

    # Returns [IOStreams::Builder] a copy to display, for example by `#inspect`, with the value of each sensitive
    # option, such as a passphrase, replaced. Each stream's format decides which of its options are sensitive,
    # see `IOStreams::StreamFormat#redact_options`.
    def redacted
      copy = dup
      copy.redact!
      copy
    end

    # Does not display the values of sensitive options, see #redacted.
    def inspect
      copy = redacted
      "#<#{self.class.name} @file_name=#{file_name.inspect}, @streams=#{copy.streams.inspect}, " \
        "@options=#{copy.options.inspect}>"
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

    protected

    # Replaces the value of each sensitive option of this copy, see #redacted.
    def redact!
      @streams = redact(@streams) if @streams
      @options = redact(@options) if @options
    end

    private

    # Returns [Hash<Symbol:Hash>] the options of each stream with the value of each sensitive option replaced,
    # or every value of a stream whose format is no longer registered, since it cannot say which are sensitive.
    def redact(streams)
      streams.to_h do |stream, opts|
        format = IOStreams.extensions[stream]
        next [stream, opts] unless opts.is_a?(Hash)
        next [stream, opts.transform_values { "[FILTERED]" }] unless format

        [stream, format.redact_options(opts)]
      end
    end

    def build_pipeline
      return {} unless file_name

      opts = options || {}
      # A stream that file names do not name, such as `:encode`, applies whenever its options are set, and
      # comes first, see `IOStreams::StreamFormat#file_name_extension?`. Like the options for any other stream
      # that the file name does not include, those for a stream that is no longer registered are ignored.
      built_streams = opts.select do |stream, _|
        format = IOStreams.extensions[stream]
        format && !format.file_name_extension?
      end
      parse_extensions.each { |stream| built_streams[stream] = opts[stream] || {} }
      built_streams
    end

    # Returns the format registered for the stream, see `IOStreams.register_extension`.
    def stream_format(stream)
      IOStreams.extensions[stream&.to_sym] || raise(ArgumentError, "Unknown Stream type: #{stream.inspect}")
    end

    # Returns the streams for the supplied file_name
    def parse_extensions
      parts      = Utils.file_name_extensions(file_name)
      extensions = []
      while (extension = parts.pop)
        sym    = extension.to_sym
        format = IOStreams.extensions[sym]
        break unless format&.file_name_extension?

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

    # Asks the stream's format to open its reader or writer, see `IOStreams::StreamFormat#open_stream`.
    def open_stream(type, stream, io_stream, opts, &)
      stream_format(stream).open_stream(type, io_stream, opts, name: stream, file_name: file_name, &)
    end
  end
end
