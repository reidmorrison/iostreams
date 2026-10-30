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
      @named_format  = nil
      @set_format    = nil
      @format_option = nil
      @encoding      = nil
      @raw           = false
      @schema        = nil
      @schema_source = nil
    end

    # A copy has its own streams, options and encoding, so that changing them does not change the original. It shares
    # the schema, which #schema= replaces rather than changes, so that the copies read its file once, see
    # `IOStreams::Schema::Source`.
    def initialize_copy(source)
      super
      @streams  = @streams&.transform_values(&:dup)
      @options  = @options&.transform_values(&:dup)
      @encoding = @encoding&.dup
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
      add_option(stream, options)
      warn_deprecated_stream("option", stream)
      warn_deprecated_options(stream, options)
      self
    end

    # Setting the encode stream with `stream(:encode, ...)` is deprecated, see #encoding. Like any other stream set
    # with `#stream`, it still stops the streams being taken from the file name, which #encoding keeps.
    #
    # Supplying `:none` is deprecated, see #raw. Since it does what #raw does, it can still be supplied after #raw.
    #
    # Each reports a deprecation warning, see `IOStreams::Deprecation`.
    def stream(stream, **options)
      stream = stream.to_sym unless stream.is_a?(Symbol)
      raise_if_raw!("#stream") unless stream == :none
      add_stream(stream, options)
      warn_deprecated_stream("stream", stream)
      warn_deprecated_options(stream, options)
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
    # as an argument and as the `encoding:` option, or for an option that the encode stream does not take, or a value
    # that it does not accept, see `IOStreams::Encode.check`. They are checked when they are set, since a writer that
    # raised for them would have replaced its file. The options set with `#option` or `#stream` for `:encode` are
    # deprecated, and are still only checked when the stream is opened, as before.
    def encoding(encoding = nil, **options)
      raise_if_raw!("#encoding")
      if encoding
        raise(ArgumentError, "Supply the encoding as an argument or as `encoding:`, not both") if options.key?(:encoding)

        options = {encoding: encoding, **options}
      end
      raise(ArgumentError, "Supply the encoding, or options for the encode stream") if options.empty?

      merged = (@encoding || {}).merge(options)
      Encode.check(**merged)
      @encoding = merged
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

    # Returns [true|false] whether the text that the streams yield is taken as UTF-8: the text of a file with a
    # schema, see #schema=, unless the application chose the encoding of its text, with an encode stream, whether set
    # with #encoding, #option, #stream, or by a file name ending in `.encode`, or chose none with #raw, which reads the
    # data as it is stored. Without a schema, the text is read as it always was.
    def utf8_text?
      !@schema.nil? && !raw? && !pipeline.key?(:encode)
    end

    # Applies no streams, including an encoding set with #encoding, as `stream(:none)` does, for IOStreams itself.
    def no_streams
      @streams  = {}
      @encoding = nil
      self
    end

    # Sets the options of a stream as #option does, unless streams were already set with #stream, or no file name is
    # set, when it adds the stream as #stream does.
    #
    # Setting the encode stream with `option_or_stream(:encode, ...)` is deprecated, see #encoding, and reports a
    # deprecation warning, see `IOStreams::Deprecation`.
    def option_or_stream(stream, **options)
      stream = stream.to_sym unless stream.is_a?(Symbol)
      raise_if_raw!("#option_or_stream") unless stream == :none
      streams || file_name.nil? ? add_stream(stream, options) : add_option(stream, options)
      warn_deprecated_stream("option_or_stream", stream)
      warn_deprecated_options(stream, options)
      self
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
    #
    # The format that the file name names is kept once it is found, until a format is set, see #format=.
    def format
      @set_format || (@named_format ||= file_name ? Tabular.format_from_file_name(file_name) : nil)
    end

    # Sets the tabular format, or nil to detect it from the file name again, see #format.
    def format=(format)
      unless format.nil? || IOStreams::Tabular.registered_formats.include?(format)
        raise(ArgumentError, "Invalid format: #{format.inspect}")
      end

      @set_format   = format
      @named_format = nil
    end

    # Returns [true|false] whether a format was set, see #format=, rather than taken from the file name, see #format.
    def format_set?
      !@set_format.nil?
    end

    # Returns [Symbol|nil] the tabular format of the text that the stream closest to the application reads, when that
    # stream decides it, such as `:csv` for a spreadsheet, whose rows it reads as CSV, see
    # `IOStreams::Xlsx::Reader.text_format`, otherwise nil, for a stream whose data is the text, such as gzip. The encode
    # stream converts that text, so it is the stream after it.
    def text_format
      stream = pipeline.each_key.find { |name| name != :encode }
      klass  = stream && IOStreams.extensions[stream]&.reader_class
      klass.text_format if klass.respond_to?(:text_format)
    end

    # A format set with #format= that is not the format of the text that the streams read, see #text_format, such as
    # `:psv` for a spreadsheet, whose rows are read as CSV, is deprecated, since v3.0 raises ArgumentError when its
    # lines, rows or records are read, rather than read them in that format. Reports a deprecation warning when they are
    # read, as v3.0 raises then, whichever way the streams were set.
    #
    # So is reading them in the format that the file name names, such as `:psv` for `report.psv.xlsx`, without a format
    # set, since v3.0 reads them in the format of the text whatever the file name, so that `format(:csv)` reads them
    # the same in both versions.
    #
    # Neither is looked for while deprecation warnings are off, see `IOStreams::Deprecation.on?`, since finding the
    # format of the text would build the pipeline once more for each read.
    def warn_text_format
      return unless Deprecation.on?

      format = self.format
      return if format.nil?

      text_format = self.text_format
      return if text_format.nil? || format == text_format

      if @set_format
        Deprecation.warn("format(#{format.inspect}) is deprecated when the streams read the rows as " \
                         "#{text_format.inspect}, such as those of a spreadsheet, since v3.0 raises ArgumentError for " \
                         "it, set format(#{text_format.inspect}) instead, or no format")
      else
        Deprecation.warn("the format #{format.inspect} that the file name names is deprecated when the streams read " \
                         "the rows as #{text_format.inspect}, such as those of a spreadsheet, since v3.0 reads them as " \
                         "#{text_format.inspect} whatever the file name, set format(#{text_format.inspect}) to read " \
                         "them so in both versions")
      end
    end

    # Returns [Array(Array<Symbol>, String, Hash|nil)|nil] the methods that the stream that the application's block
    # receives in v3.0 answers, its name for a deprecation warning, such as "the :gz stream", and what replaces each
    # method that v3.0 removes, when the stream says, see `IOStreams::Reader.v3_stream_advice`, when the stream that it
    # receives in v2.2 answers others, otherwise nil. The stream closest to the application decides, with its options,
    # see `IOStreams::Reader.v3_stream_methods`. Without any streams, the block receives the IO that they would read or
    # write, which the supplied source describes, see `IOStreams::Stream#v3_source` and `IOStreams::Stream#v3_target`.
    #
    # Parameters:
    #   type: [:reader|:writer]
    #   source: [Array(Array<Symbol>, String)|nil]
    #     The methods and the name of the IO that the streams read or write in v3.0, when it differs from the one in
    #     v2.2, otherwise nil.
    #
    # Yields, only when the stream closest to the application asks and is the only stream, to ask whether the streams
    # read a regular local file in v3.0. The block answers true or false.
    #
    # Asked before the streams are opened, so it raises nothing, not even for a stream without a class of the type, which
    # raises as before once it is opened.
    def v3_stream(type, source)
      streams       = pipeline
      name, options = streams.first
      return source if name.nil?

      klass = IOStreams.extensions[name]&.public_send(:"#{type}_class")
      return unless klass.respond_to?(:v3_stream_methods)

      methods = klass.v3_stream_methods(options) { streams.size == 1 && yield }
      return unless methods

      [methods, "the #{name.inspect} stream", (klass.v3_stream_advice if klass.respond_to?(:v3_stream_advice))]
    end

    # Returns [Symbol|nil] the format that the rows and records of this file are read and written in, when IOStreams
    # v3.0 reads and writes them in its `:text` format instead, as the text of each line: when no format was set, so
    # that it is taken from a file name whose format extension is `.text`, see `IOStreams::Tabular.text_file_format`,
    # unless a stream reads the lines in a format of its own, such as the CSV of a spreadsheet, which v3.0 reads them
    # in, whatever format the file name names. Returns nil otherwise.
    def text_file_format
      return if format_set? || file_name.nil? || text_format

      Tabular.text_file_format(file_name)
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

    # Returns [Hash<Symbol, Array<Symbol>>] the settings of this stream that apply to what it writes, other than the
    # options of each call: `streams:` the names of the streams of its pipeline, see #pipeline, which #stream, #option,
    # #encoding and the file name set, and `tabular:` the names of those of its rows and records that were set: `:format`,
    # when it was set, see #format=, rather than taken from the file name, and `:schema`, see #schema=.
    def writer_settings
      tabular = []
      tabular << :format if format_set?
      tabular << :schema unless schema.nil?
      {streams: pipeline.keys, tabular: tabular}
    end

    private

    # Sets the options of a stream that is applied once the file name extensions have been parsed, see #option.
    def add_option(stream, options)
      raise(ArgumentError, "Invalid stream: #{stream.inspect}") unless IOStreams.extensions.include?(stream)
      raise(ArgumentError, "Cannot call both #option and #stream on the same streams instance}") if @streams
      raise(ArgumentError, "Cannot call #option unless the `file_name` was already set}") unless file_name

      @options ||= {}
      if (opts = @options[stream])
        opts.merge!(options)
      else
        @options[stream] = options.dup
      end
    end

    # Adds a stream, in place of the streams that the file name implies, see #stream.
    def add_stream(stream, options)
      raise(ArgumentError, "Cannot call both #option and #stream on the same streams instance}") if @options
      # `:none` applies no streams, including an encoding set with #encoding. It is the deprecated form of #raw.
      return no_streams if stream == :none
      raise(ArgumentError, "Invalid stream: #{stream.inspect}") unless IOStreams.extensions.include?(stream)

      @streams ||= {}
      if (opts = @streams[stream])
        opts.merge!(options)
      else
        @streams[stream] = options.dup
      end
    end

    # Reports a deprecation warning for supplying `:none`, see #raw, or for setting the encode stream, see #encoding,
    # which names the method that the application called.
    def warn_deprecated_stream(method, stream)
      case stream
      when :none
        Deprecation.warn("#{method}(:none) is deprecated, use #raw to read or write the data as it is stored, " \
                         "or #file_name to read a file that is not named for its format")
      when :encode
        # Like any other stream set with #stream, stream(:encode, ...) stops the streams being taken from the file
        # name, which #encoding keeps.
        if method == "stream"
          Deprecation.warn("stream(:encode, ...) is deprecated, use #encoding instead, which keeps the streams that " \
                           "the file name implies, #raw to read or write the data as it is stored, or #file_name to " \
                           "read a file that is not named for its format")
        else
          Deprecation.warn("#{method}(:encode, ...) is deprecated, use #encoding instead")
        end
      end
    end

    # Reports a deprecation warning for each option of the stream that IOStreams 3.0 raises ArgumentError for when it is
    # set with #option, #stream or #option_or_stream, whether or not the file name includes the stream, so that it is
    # reported wherever the code runs, rather than only where a file name includes the stream: one that the reader or
    # the writer of the stream replaces, with the option that replaces it, see
    # `IOStreams::Deprecation::OptionNames#replaced_option_names`, and one that neither of them takes in IOStreams 3.0,
    # such as a misspelled one, see #v3_option_names. An option of the other direction is not reported, since v3.0
    # accepts it, and ignores it, nor are the options of the encode stream, which is deprecated itself, see
    # #warn_deprecated_stream, or of `:none`, which takes none.
    def warn_deprecated_options(stream, options)
      return if options.empty? || %i[encode none].include?(stream)

      classes  = v3_stream_classes(stream)
      replaced = classes.each_with_object({}) do |klass, names|
        names.merge!(klass.replaced_option_names) if klass.respond_to?(:replaced_option_names)
      end.slice(*options.keys)
      replaced.each_pair { |name, replacement| Deprecation.warn("#{name}: is deprecated, use #{replacement}: instead") }

      known = v3_option_names(classes)
      names = known ? options.keys - replaced.keys - known : []
      return if names.empty?

      words = Deprecation::Words.new(names)
      Deprecation.warn("#{words.keywords} #{words.are} deprecated for a #{stream.inspect} stream, since neither its " \
                       "reader nor its writer takes #{words.them}, so correct or remove #{words.them}")
    end

    # Returns [Array<Class|Module>] the classes that read and write the stream in IOStreams 3.0, as far as they are
    # known: the reader and the writer registered for it, and, in place of a writer that it does not have, the stand-in
    # for the one that IOStreams 3.0 adds, when its reader names one, such as for `.xlsx`, see
    # `IOStreams::Xlsx::Reader.v3_writer`. None when the stream is not registered.
    def v3_stream_classes(stream)
      extension = IOStreams.extensions[stream]
      return [] unless extension

      reader   = extension.reader_class
      writer   = extension.writer_class
      writer ||= reader.v3_writer if reader.respond_to?(:v3_writer)
      [reader, writer].compact
    end

    # Returns [Array<Symbol>|nil] the options that IOStreams 3.0 accepts when they are set for a stream of the supplied
    # classes, see #v3_stream_classes: those that its reader or its writer takes, or nil when they are not known, since
    # a class does not declare them, as one that an application registers need not.
    def v3_option_names(classes)
      names = classes.map { |klass| v3_class_option_names(klass) }
      names.flatten.uniq unless names.empty? || names.include?(nil)
    end

    # Returns [Array<Symbol>|nil] the options that the class takes in IOStreams 3.0, see
    # `IOStreams::Deprecation::OptionNames#known_option_names`, or those that it declares when it does not answer them,
    # as a class that an application registers need not, or nil when it does neither.
    def v3_class_option_names(klass)
      return klass.known_option_names if klass.respond_to?(:known_option_names)

      klass.option_names if klass.respond_to?(:option_names)
    end

    # A file name ending in `.encode` is deprecated, since file names do not name the encode stream, see #encoding.
    # Once the encode stream is set, with #encoding or `option(:encode, ...)`, the file name adds nothing to it, so it
    # is only reported when the file name is what applies the encode stream.
    def warn_encode_extension
      return if streams || @encoding || options&.key?(:encode)
      return if file_name.nil? || !parse_extensions.include?(:encode)

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

      {encode: encode_setting}.merge(pipeline.except(:encode))
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
      parts      = Utils::PathName.basename(file_name).split(".")
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
      klass.open(io_stream, **taken_options(type, stream, klass, opts), &)
    end

    # Returns [Hash] the options of the stream that the class is opened with: all of them, unless the class takes any
    # option, since it does not declare them, see #validate_options, while it answers those that it takes in IOStreams
    # 3.0, as `IOStreams::Bzip2::Reader` does until v3.0, see #v3_class_option_names. It is then opened with those
    # alone, and a warning is logged for each of the others, which it would ignore, see
    # `IOStreams::Utils.warn_unknown_options`, naming the stream as it was set: one that the class of the other
    # direction takes, which v3.0 accepts, and ignores, or one that neither takes, which v3.0 raises ArgumentError for.
    def taken_options(type, stream, klass, opts)
      known = v3_class_option_names(klass) if option_names(klass).nil?
      return opts if known.nil?

      unknown = opts.except(*known)
      return opts if unknown.empty?

      other       = IOStreams.extensions[stream].public_send(type == :reader ? :writer_class : :reader_class)
      other_names = (v3_class_option_names(other) if other) || []
      Utils.warn_unknown_options(unknown, stream, type, known, other_names)
      opts.slice(*known)
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
