module IOStreams
  # Build the streams that need to be applied to a path during reading or writing.
  class Builder
    attr_accessor :file_name, :format_options
    attr_reader :streams, :options

    # Returns [Hash|String|IOStreams::Stream|nil] the schema of the rows and records as it was set, see #schema=.
    attr_reader :schema

    def initialize(file_name = nil)
      @file_name     = file_name
      @streams       = nil
      @options       = nil
      @format        = nil
      @format_option = nil
      @encoding      = nil
      @raw           = false
      @schema        = nil
      @schema_source = nil
    end

    # Sets the schema of the rows and records, see `IOStreams::Stream#schema`: a Hash, which is checked now, or the path
    # or url of a JSON file that holds one, which is read the first time that a reader or writer needs it, see
    # `IOStreams::Schema::Source`, or nil to remove it.
    #
    # A copy of a Hash or String is held, which is frozen, so that the caller changing the object that it supplied
    # changes neither #schema nor the schema that is read, and a copy of a path, so that changing its path does not
    # change the schema.
    #
    # Raises ArgumentError when the schema is not a Hash, a String or a path, or is a Hash that is not a valid schema.
    def schema=(schema)
      schema         = schema.is_a?(IOStreams::Stream) ? schema.dup : Utils.frozen_copy(schema)
      @schema_source = schema.nil? ? nil : IOStreams::Schema::Source.new(schema)
      @schema        = schema
    end

    # Returns [IOStreams::Schema|nil] the schema of the rows and records, reading its file the first time, see #schema=,
    # or nil when none is set.
    def tabular_schema
      @schema_source&.schema
    end

    # Supply an option that is only applied once the file name extensions have been parsed.
    # Note:
    # - Cannot set both `stream` and `option`
    #
    # Setting the encode stream with `option(:encode, ...)` is deprecated, see #encoding, and reports a deprecation
    # warning, see `IOStreams::Deprecation`.
    def option(stream, **options)
      stream = stream.to_sym unless stream.is_a?(Symbol)
      raise_if_raw!("#option")
      raise(ArgumentError, "Invalid stream: #{stream.inspect}") unless IOStreams.extensions.include?(stream)
      raise(ArgumentError, "Cannot call both #option and #stream on the same streams instance}") if @streams
      raise(ArgumentError, "Cannot call #option unless the `file_name` was already set}") unless file_name

      @options ||= {}
      if (opts = @options[stream])
        opts.merge!(options)
      else
        @options[stream] = options.dup
      end
      Deprecation.warn("option(:encode, ...) is deprecated, use #encoding instead") if stream == :encode
      self
    end

    # Setting the encode stream with `stream(:encode, ...)` is deprecated, see #encoding. Like any other stream set
    # with `#stream`, it still stops the streams being taken from the file name.
    #
    # Supplying `:none` is deprecated, see #raw.
    #
    # Each reports a deprecation warning, see `IOStreams::Deprecation`.
    def stream(stream, **options)
      stream = stream.to_sym unless stream.is_a?(Symbol)
      raise_if_raw!("#stream")
      raise(ArgumentError, "Cannot call both #option and #stream on the same streams instance}") if @options

      # To prevent any streams from being applied, including an encoding set with #encoding, supply a stream named
      # `:none`
      if stream == :none
        Deprecation.warn("stream(:none) is deprecated, use #raw to read or write the data as it is stored, " \
                         "or #file_name to read a file that is not named for its format")
        return no_streams
      end
      raise(ArgumentError, "Invalid stream: #{stream.inspect}") unless IOStreams.extensions.include?(stream)

      @streams ||= {}
      if (opts = @streams[stream])
        opts.merge!(options)
      else
        @streams[stream] = options.dup
      end
      Deprecation.warn("stream(:encode, ...) is deprecated, use #encoding instead") if stream == :encode
      self
    end

    # Sets the encoding of the text that the application reads or writes, and the other options of the encode
    # stream, see `IOStreams::Encode`, merging them with those already set.
    #
    # Unlike `#option`, it can be combined with `#stream`, and needs no file name. Unlike `#stream`, it does not stop
    # the streams being taken from the file name. The encode stream is applied closest to the application, after
    # every other stream when reading, with the options set by `#option` or `#stream` for `:encode`, if any, and
    # these on top of them.
    #
    # Raises ArgumentError when neither an encoding nor any options are supplied, when the encoding is supplied both
    # as an argument and as the `encoding:` option, or for an option that the encode stream does not take.
    def encoding(encoding = nil, **options)
      raise_if_raw!("#encoding")
      if encoding
        raise(ArgumentError, "Supply the encoding as an argument or as `encoding:`, not both") if options.key?(:encoding)

        options = {encoding: encoding, **options}
      end
      raise(ArgumentError, "Supply the encoding, or options for the encode stream") if options.empty?

      unknown = options.keys - encode_option_names
      if unknown.any?
        raise(ArgumentError, "Unknown encoding #{unknown.size == 1 ? 'option' : 'options'} #{list(unknown)}. " \
                             "Valid options: #{list(encode_option_names)}.")
      end

      @encoding = (@encoding || {}).merge(options)
      self
    end

    # Reads and writes the data as it is stored: applies no streams, neither those that the file name implies nor any
    # already set with #stream or #option, and no encoding set with #encoding. For example, to download a zip file
    # without unzipping it, or to write data that is already compressed.
    #
    # Since the data is as stored, setting a stream, option or encoding afterwards raises ArgumentError.
    def raw
      no_streams
      @options = nil
      @raw     = true
      self
    end

    # Returns [true|false] whether the data is read and written as it is stored, see #raw.
    def raw?
      @raw
    end

    # Applies no streams, including an encoding set with #encoding, as `stream(:none)` does, for IOStreams itself.
    def no_streams
      @streams  = {}
      @encoding = nil
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
      return encode_setting if stream == :encode && @encoding
      return streams[stream] if streams

      options[stream] if options
    end

    def reader(io_stream, &)
      warn_encode_extension
      execute(:reader, pipeline, io_stream, &)
    end

    def writer(io_stream, &)
      warn_encode_extension
      execute(:writer, pipeline, io_stream, &)
    end

    # Returns [Hash<Symbol:Hash>] the pipeline of streams
    # with their options that will be applied when the reader or writer is invoked.
    def pipeline
      with_encoding(streams ? streams.dup : build_pipeline).freeze
    end

    # Removes the named stream from the current pipeline.
    # If the stream pipeline has not yet been built it will be built from the file_name if present.
    # Note: Any options must be set _before_ calling this method.
    def remove_from_pipeline(stream_name)
      @streams ||= build_pipeline
      @encoding  = nil if stream_name.to_sym == :encode
      @streams.delete(stream_name.to_sym)
    end

    # Returns the tabular format if set, otherwise tries to autodetect the format if the file_name has been set
    # Returns [nil] if no format is set, or if it cannot be determined from the file_name
    def format
      @format ||= file_name ? Tabular.format_from_file_name(file_name) : nil
    end

    def format=(format)
      unless format.nil? || IOStreams::Tabular.registered_formats.include?(format)
        raise(ArgumentError, "Invalid format: #{format.inspect}")
      end

      @format = format
    end

    # Returns [String] the quote character within which field delimiters and newlines may be
    # embedded for the current tabular format, or [nil] when the format has no such quoting,
    # or when the format cannot be determined.
    #
    # Used by the line reader to avoid treating a newline as a line ending when it is embedded
    # within a quoted field (e.g. CSV). Delegates to the format's parser, so the per-format
    # knowledge lives with the parser. Driven entirely by `format`, so an explicitly set format
    # (e.g. `.format(:psv)`) overrides any extension auto-detected from the `file_name`.
    def quote_character
      format && IOStreams::Tabular.parser_class(format).quote_character
    end

    private

    # A file name ending in `.encode` is deprecated, since file names do not name the encode stream, see #encoding.
    def warn_encode_extension
      return if streams || file_name.nil? || !parse_extensions.include?(:encode)

      Deprecation.warn("a file name ending in .encode is deprecated, since file names do not name the encode " \
                       "stream, use #encoding instead")
    end

    def raise_if_raw!(method_name)
      return unless @raw

      raise(ArgumentError, "Cannot call #{method_name} after #raw, which reads and writes the data as it is stored")
    end

    # Returns [Hash] the options of the encode stream set with #option or #stream, if any, and those of #encoding.
    def encode_setting
      setting = streams ? streams[:encode] : options&.[](:encode)
      (setting || {}).merge(@encoding)
    end

    # Returns [Hash<Symbol:Hash>] the pipeline, with the encode stream first, closest to the application, when an
    # encoding was set with #encoding.
    def with_encoding(pipeline)
      return pipeline unless @encoding

      encode = (pipeline[:encode] || {}).merge(@encoding)
      pipeline.delete(:encode)
      {encode: encode}.merge(pipeline)
    end

    def encode_option_names
      (Encode::Reader.option_names + Encode::Writer.option_names).uniq
    end

    def build_pipeline
      return {} unless file_name

      built_streams          = {}
      # Encode stream is always first
      built_streams[:encode] = options[:encode] if options&.key?(:encode)

      opts = options || {}
      parse_extensions.each { |stream| built_streams[stream] = opts[stream] || {} }
      built_streams
    end

    def class_for_stream(type, stream)
      ext = IOStreams.extensions[stream&.to_sym] ||
            raise(ArgumentError, "Unknown Stream type: #{stream.inspect}")
      ext.send("#{type}_class") || raise(ArgumentError, "No #{type} registered for Stream type: #{stream.inspect}")
    end

    # Returns the streams for the supplied file_name
    def parse_extensions
      parts      = ::File.basename(file_name).split(".")
      extensions = []
      while (extension = parts.pop)
        sym = extension.downcase.to_sym
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
      validate_options(type, stream, klass, opts)
      klass.open(io_stream, **opts, &)
    end

    # Options are strict: an option the stream does not accept raises instead of being ignored.
    # One option hash is shared by the reader and the writer for a stream, so when the option
    # is only valid in the other direction the message says so.
    #
    # Streams registered via `IOStreams.register_extension` need not inherit from `IOStreams::Reader`
    # or `IOStreams::Writer`, so a class that does not declare `option_names` is not validated here.
    def validate_options(type, stream, klass, opts)
      accepted = option_names(klass)
      return if accepted.nil?

      unknown = opts.keys - accepted
      return if unknown.empty?

      other_type  = type == :reader ? :writer : :reader
      other_names = option_names(IOStreams.extensions[stream].send("#{other_type}_class")) || []
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
        valid = accepted.empty? ? "none" : list(accepted)
        messages << "Unknown #{invalid.size == 1 ? 'option' : 'options'} #{list(invalid)} when #{direction} " \
                    "a #{stream.inspect} stream. Valid options: #{valid}."
      end
      raise(ArgumentError, messages.join(" "))
    end

    def option_names(klass)
      klass.option_names if klass.respond_to?(:option_names)
    end

    def list(names)
      names.map(&:inspect).join(", ")
    end
  end
end
