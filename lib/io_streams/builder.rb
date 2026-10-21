# frozen_string_literal: true

module IOStreams
  # Build the streams that need to be applied to a path during reading or writing.
  #
  # It holds the streams that read and write the bytes of a file, and their options. The settings that describe the rows
  # of the file, such as the options of the rows of a Parquet file, are held apart, see `IOStreams::Tabular::Settings`.
  class Builder
    attr_accessor :file_name
    attr_reader :streams, :options

    # Keywords that `#option` and `#stream` give a meaning of their own, so that they cannot be registered as a
    # file name extension with `IOStreams.register_extension`:
    #   :encode
    #     The built-in encode stream, see `IOStreams::Encode`. It converts the text that the application reads or
    #     writes, so file names do not name it. It applies whenever its options are set with `#encoding`, and is
    #     always closest to the application. Setting it with `#option` or `#stream` is deprecated, but still works.
    #   :none
    #     Supplied to `#stream` to apply no streams, including an encode stream set with `#encoding`. Text is still
    #     read and written in its default encoding, see #text_reader and #with_default_encoding, since that belongs
    #     to the text, not to a stream. Set an encoding with `#encoding` afterwards, such as "BINARY", to change it.
    #     Deprecated, see #raw, which reads and writes the data as stored, without any encoding.
    RESERVED_KEYWORDS = %i[encode none].freeze

    # Returns [true|false] whether the name is a reserved keyword, see `RESERVED_KEYWORDS`.
    def self.reserved_keyword?(name)
      RESERVED_KEYWORDS.include?(name)
    end

    # Returns [true|false] whether `#option` and `#stream` take the supplied name, a Symbol, as a stream of this builder:
    # a reserved keyword, see `RESERVED_KEYWORDS`, or a file name extension registered with `IOStreams.register_extension`,
    # in any case, see `IOStreams::Utils.extension_name`.
    def self.stream_name?(name)
      name = Utils.extension_name(name)
      reserved_keyword?(name) || !IOStreams.extension(name).nil?
    end

    # Returns the format of the stream, such as `IOStreams::Gzip` for `:gz` or `:GZ`, or nil when it is not registered.
    def self.find_format(stream)
      stream = Utils.extension_name(stream)
      stream == :encode ? Encode : IOStreams.extension(stream)
    end

    def initialize(file_name = nil)
      @file_name = file_name
      @streams   = nil
      @options   = nil
      @encoding  = nil
      @raw       = false
    end

    # Freezes this builder, holding frozen copies of its streams and options, so that neither its methods nor a change to
    # the Hashes that #setting and #pipeline return can change it, see `IOStreams::Stream#freeze`. The objects that the
    # caller supplied are not frozen.
    def freeze
      @streams  = Utils.frozen_copy(@streams)
      @options  = Utils.frozen_copy(@options)
      @encoding = Utils.frozen_copy(@encoding)
      super
    end

    # A copy has its own streams and options, so that changing them does not change the original.
    def initialize_copy(source)
      super
      @streams  = @streams&.transform_values(&:dup)
      @options  = @options&.transform_values(&:dup)
      @encoding = @encoding&.dup
    end

    # Supply an option that is only applied once the file name extensions have been parsed.
    # Note:
    # - An option for a format applies to each of its extensions, such as `option(:pgp, ...)` to a `.gpg` file,
    #   `option(:gz, ...)` to a `.gzip` file, and `option(:xlsx, ...)` to a `.xlsm` file. When options are set for
    #   more than one extension of a format, those for the extension in the file name take precedence.
    # - Cannot set both `stream` and `option`
    # - Raises ArgumentError for an option that neither the reader nor the writer for the stream accepts,
    #   even when the file name does not include the stream. So a misspelled option raises wherever the code
    #   runs, rather than only where the path, for example from configuration, includes the stream.
    # - The name of the stream is compared without case, as the extensions of a file name are, so `option(:GZ, ...)`
    #   sets the options of `:gz`, see `IOStreams::Utils.extension_name`. So do #stream, #setting and
    #   #remove_from_pipeline.
    #
    # Setting the encode stream with `option(:encode, ...)` is deprecated, see #encoding, which it calls, and reports a
    # deprecation warning, see `IOStreams::Deprecation`.
    def option(stream, **options)
      stream = Utils.extension_name(stream)
      raise_if_raw!("#option")
      add_option(stream, options)
      warn_deprecated_stream("option", stream)
      self
    end

    # Setting the encode stream with `stream(:encode, ...)` is deprecated, see #encoding. Like any other stream
    # set with `#stream`, it still stops the streams being taken from the file name, which #encoding keeps.
    #
    # Supplying `:none` is deprecated, see #raw. Since it applies no streams, as #raw does, it can still be supplied
    # after #raw, which it leaves as it is.
    #
    # Each reports a deprecation warning, see `IOStreams::Deprecation`.
    def stream(stream, **options)
      stream = Utils.extension_name(stream)
      raise_if_raw!("#stream") unless stream == :none
      add_stream(stream, options)
      warn_deprecated_stream("stream", stream)
      self
    end

    # Sets the encoding of the text that the application reads or writes, and the other options of the built-in
    # encode stream, see `IOStreams::Encode`, merging them with those already set.
    #
    # Unlike `#option`, it can be combined with `#stream`, and needs no file name. Unlike `#stream`, it does not
    # stop the streams being taken from the file name.
    #
    # Raises ArgumentError when neither an encoding nor any options are supplied, when the encoding is supplied
    # both as an argument and as the `encoding:` option, or for an option that the encode stream does not take.
    def encoding(encoding = nil, **options)
      if encoding
        raise(ArgumentError, "Supply the encoding as an argument or as `encoding:`, not both") if options.key?(:encoding)

        options = {encoding: encoding, **options}
      end
      raise(ArgumentError, "Supply the encoding, or options for the encode stream") if options.empty?

      merge_encoding(options)
    end

    # Reads and writes the data as it is stored: applies no streams, neither those that the file name implies nor
    # any already set with #stream or #option, and no encoding, so text is read and written as bytes. For example,
    # to download a zip file without unzipping it, or to write data that is already compressed.
    #
    # Since the data is as stored, setting a stream, option or encoding afterwards raises ArgumentError. To read a
    # file whose name implies the wrong streams, set the file name that names its format instead.
    def raw
      @streams  = {}
      @options  = nil
      @encoding = nil
      @raw      = true
      self
    end

    # Returns [true|false] whether the data is read and written as it is stored, see #raw.
    def raw?
      @raw
    end

    # Sets the options of the stream as #option does when the file name is known and no streams were set, otherwise as
    # #stream does. Setting the encode stream with `option_or_stream(:encode, ...)`, or supplying `:none`, is deprecated
    # as it is for those, and reports a deprecation warning that names this method, see `IOStreams::Deprecation`.
    def option_or_stream(stream, **options)
      stream = Utils.extension_name(stream)
      raise_if_raw!("#option_or_stream") unless stream == :none
      streams || file_name.nil? ? add_stream(stream, options) : add_option(stream, options)
      warn_deprecated_stream("option_or_stream", stream)
      self
    end

    # Returns [IOStreams::Builder] a copy that reads and writes text through the encode stream in the supplied
    # encoding, unless an encoding was already set, see #encoding. The other encode options already set,
    # such as `replace` and `cleaner`, are kept.
    #
    # So that a format whose text has an encoding of its own, such as fixed width files, see
    # `IOStreams::Tabular#encoding`, uses it by default, while the caller can still set the encoding of the data.
    #
    # After #raw the copy reads and writes the data as stored, without an encoding.
    def with_default_encoding(encoding)
      copy = dup
      copy.encoding(encoding) unless raw? || setting(:encode)&.key?(:encoding)
      copy
    end

    # Return the options set for either a stream or option.
    def setting(stream)
      stream = Utils.extension_name(stream)
      return @encoding if stream == :encode
      return streams[stream] if streams

      options[stream] if options
    end

    # Yields the stream that reads the supplied stream through this pipeline. A stream whose failures name the file that
    # it reads, such as zip, names it by the display name, such as the url of a path, see `IOStreams::Path#display_name`,
    # otherwise by the file name, see `IOStreams::Reader.takes_display_name?`.
    def reader(io_stream, display_name: nil, &)
      execute(:reader, pipeline, io_stream, display_name: display_name || file_name, &)
    end

    # Raises what writing through the pipeline would raise before anything is written, such as an option value that a
    # stream does not accept, or the gem of a stream that is not installed, as each stream's format answers, see
    # `IOStreams::StreamFormat#check_stream`. So that a path can check before it opens its output, which would replace
    # an existing file, see `IOStreams::Stream#open_writer`.
    def check_writer
      pipeline.each_pair do |stream, opts|
        stream_format(stream).check_stream(:writer, opts, name: stream, file_name: file_name)
      end
      nil
    end

    # Yields the stream that writes to the supplied stream through this pipeline.
    #
    # The streams write bytes, those of a compressed or encrypted stream, or of text in the encoding set with
    # #encoding, which the supplied stream stores as they are, even when it converts the text written to it, such as a
    # `StringIO`, see `IOStreams::BytesOutput`. Without any streams, or with only an encode stream that sets no
    # encoding, such as one that only cleanses the text, the block writes text to the supplied stream itself, which
    # converts it, as it converts the text written to it without IOStreams.
    def writer(io_stream, &)
      pipeline = self.pipeline
      output   = writes_bytes?(pipeline) ? BytesOutput.for(io_stream) : io_stream
      execute(:writer, pipeline, output, &)
    end

    # Yields a stream that reads the supplied stream, which reads the data through this pipeline, as text,
    # for reading lines, rows or records.
    #
    # Text is decoded by the built-in encode stream, see `IOStreams::Encode`. So unless the pipeline already
    # includes it, see #encoding, the supplied stream is read through the encode stream with its
    # default options, which read UTF-8. After #raw the supplied stream is read as bytes.
    def text_reader(io_stream, &)
      return yield(io_stream) if raw? || pipeline.key?(:encode)

      open_stream(:reader, :encode, io_stream, {}, &)
    end

    # Returns [String] the whole of the data that was read through this pipeline, as text.
    #
    # Like `File.read`, the data is tagged with the default encoding of the encode stream, UTF-8, without checking
    # that it is valid, so that a binary file can be read too, since its bytes are unchanged. The data is returned
    # as it is when the pipeline includes the encode stream, which gave it its encoding, or when the pipeline is
    # empty and the data has an encoding other than binary, which the supplied stream gave it, such as an IO opened
    # with an external encoding. After #raw the data is returned as it was read.
    def text(data)
      return data if data.nil? || raw? || pipeline.key?(:encode)
      return data if pipeline.empty? && data.encoding != Encoding::BINARY

      encoding = Encode.default_encoding
      data.frozen? ? data.dup.force_encoding(encoding) : data.force_encoding(encoding)
    end

    # Returns [Hash<Symbol:Hash>] the pipeline of streams
    # with their options that will be applied when the reader or writer is invoked.
    #
    # The streams are in order from the one closest to the application to the one closest to the data. The encode
    # stream, which converts the text that the application reads or writes, comes first, see #encoding.
    def pipeline
      encode = @encoding ? {encode: @encoding} : {}
      encode.merge(streams || build_pipeline).freeze
    end

    # Removes the named stream from the current pipeline.
    # If the stream pipeline has not yet been built it will be built from the file_name if present.
    # Note: Any options must be set _before_ calling this method.
    def remove_from_pipeline(stream_name)
      @streams ||= build_pipeline
      stream_name = Utils.extension_name(stream_name)
      return @streams.delete(stream_name) unless stream_name == :encode

      encoding  = @encoding
      @encoding = nil
      encoding
    end

    # Returns [IOStreams::Builder] a copy to display, for example by `#inspect`, with the value of each sensitive
    # option, such as a passphrase, replaced. Each stream's format decides which of its options are sensitive,
    # see `IOStreams::StreamFormat#redact_options`.
    def redacted
      copy = dup
      copy.redact!
      copy
    end

    # Does not display the values of sensitive options, see #inspect_fields.
    def inspect
      "#<#{self.class.name} @file_name=#{file_name.inspect}#{inspect_fields}#{inspect_pipeline}>"
    end

    # Returns [String] the streams, options and encoding that are set, each one only when it is set, for #inspect, and
    # for `#inspect` on a path, see `IOStreams::Path#inspect`, which shows them before the settings of its rows. The
    # value of each sensitive option is replaced, see #redacted. The streams set with #stream are shown as `@builder`, as
    # a path has always shown them.
    def inspect_fields
      copy = redacted
      str  = +""
      str << " @builder=#{copy.streams.inspect}" if copy.streams
      str << " @options=#{copy.options.inspect}" if copy.options
      str << " @encoding=#{copy.setting(:encode).inspect}" if copy.setting(:encode)
      str
    end

    # Returns [String] the pipeline, see #pipeline, for #inspect, and for `#inspect` on a path, which shows it last, with
    # the value of each sensitive option replaced, see #redacted.
    def inspect_pipeline
      " pipeline=#{redacted.pipeline.inspect}"
    end

    # Returns [Symbol|nil] the tabular format of the text that the stream closest to the application reads and writes,
    # when its format decides it, such as `:csv` for a spreadsheet, see `IOStreams::StreamFormat#text_format`, otherwise
    # nil. The encode stream converts that text, so it is the stream after it.
    def text_format
      stream = pipeline.each_key.find { |name| name != :encode }
      stream_format(stream).text_format if stream
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

    # Replaces the value of each sensitive option of this copy, see #redacted, as the format of each stream decides, or
    # every value of a stream that is no longer registered, since then no format can say which are sensitive.
    def redact!
      @streams  = Utils.redact_streams(@streams) { |stream| self.class.find_format(stream) } if @streams
      @options  = Utils.redact_streams(@options) { |stream| self.class.find_format(stream) } if @options
      @encoding = Encode.redact_options(@encoding) if @encoding
    end

    private

    def build_pipeline
      return {} unless file_name

      parse_extensions.to_h { |stream| [stream, extension_options(stream)] }
    end

    # Returns [Hash] the options of the stream for an extension in the file name: those set for every extension of
    # its format, such as `option(:pgp, ...)` for a `.gpg` file, and then those set for the extension itself, which
    # take precedence. So a file name held in configuration can change between the extensions of a format, such as
    # from `.pgp` to `.gpg`, without the code that sets the options changing.
    def extension_options(stream)
      return {} unless options

      format = self.class.find_format(stream)
      merged = {}
      options.each_pair do |name, opts|
        merged.merge!(opts) if name != stream && self.class.find_format(name) == format
      end
      merged.merge!(options[stream]) if options.key?(stream)
      merged
    end

    # Validates the options of the encode stream and merges them with those already set, see #encoding.
    #
    # Raises ArgumentError for the name or the value of an option that the encode stream does not accept, such as an
    # encoding that Ruby does not know, see `IOStreams::Encode.check`, as soon as it is set.
    def merge_encoding(options)
      raise_if_raw!("#encoding")
      Encode.validate_options(nil, options, name: :encode)
      encoding = (@encoding || {}).merge(options)
      Encode.check(**encoding)
      @encoding = encoding
      self
    end

    # Options are strict: raise rather than ignore a setting that #raw would not apply.
    # Sets the options of a stream that is applied once the file name extensions have been parsed, see #option, or of
    # the encode stream, see #encoding.
    def add_option(stream, options)
      return merge_encoding(options) if stream == :encode

      format = self.class.find_format(stream) || raise(ArgumentError, "Invalid stream: #{stream.inspect}")
      raise(ArgumentError, "Cannot call both #option and #stream on the same streams instance") if @streams
      raise(ArgumentError, "Cannot call #option unless the `file_name` was already set") unless file_name

      format.validate_options(nil, options, name: stream)
      @options ||= {}
      if (opts = @options[stream])
        opts.merge!(options)
      else
        @options[stream] = options.dup
      end
    end

    # Adds a stream, in place of the streams that the file name implies, see #stream. `:none` applies no streams,
    # including the encode stream, and the encode stream is set as with #encoding.
    def add_stream(stream, options)
      raise(ArgumentError, "Cannot call both #option and #stream on the same streams instance") if @options

      if stream == :none
        @streams  = {}
        @encoding = nil
        return
      end
      if stream == :encode
        # Checked before the streams from the file name are replaced, so that a stream that raises changes nothing.
        merge_encoding(options)
        @streams ||= {}
        return
      end
      format = self.class.find_format(stream) || raise(ArgumentError, "Invalid stream: #{stream.inspect}")

      format.validate_options(nil, options, name: stream)
      @streams ||= {}
      if (opts = @streams[stream])
        opts.merge!(options)
      else
        @streams[stream] = options.dup
      end
    end

    # Reports a deprecation warning, see `IOStreams::Deprecation`, for supplying `:none`, see #raw, or for setting the
    # encode stream, see #encoding, which names the method that the application called.
    def warn_deprecated_stream(method, stream)
      case stream
      when :none
        Deprecation.warn("#{method}(:none) is deprecated, use #raw to read or write the data as it is stored, " \
                         "or #file_name to read a file that is not named for its format")
      when :encode
        # Like any other stream set with #stream, stream(:encode, ...) stops the streams being taken from the file name,
        # which #encoding keeps, so the replacement depends on what the application wanted.
        if method == "stream"
          Deprecation.warn("stream(:encode, ...) is deprecated, use #encoding instead, which keeps the streams that " \
                           "the file name implies, #raw to read or write the data as it is stored, or #file_name to " \
                           "read a file that is not named for its format")
        else
          Deprecation.warn("#{method}(:encode, ...) is deprecated, use #encoding instead")
        end
      end
    end

    def raise_if_raw!(method)
      return unless raw?

      raise(ArgumentError, "Cannot call #{method} after #raw, which reads and writes the data as it is stored")
    end

    # Returns the format of the stream, see .find_format, or raises when there is none.
    def stream_format(stream)
      self.class.find_format(stream) || raise(ArgumentError, "Unknown Stream type: #{stream.inspect}")
    end

    # Returns the streams for the supplied file_name
    def parse_extensions
      parts      = Utils.file_name_extensions(file_name)
      extensions = []
      while (extension = parts.pop)
        name = Utils.extension_name(extension)
        break unless IOStreams.extension(name)

        extensions.unshift(name)
      end
      extensions
    end

    # Returns [true|false] whether the streams of the pipeline write bytes to the stream that they write to, see #writer:
    # any stream but the encode stream, or the encode stream with an encoding.
    def writes_bytes?(pipeline)
      pipeline.any? { |stream, options| stream != :encode || options.key?(:encoding) }
    end

    # Executes the streams that need to be executed.
    def execute(type, pipeline, io_stream, display_name: nil, &block)
      raise(ArgumentError, "IOStreams call is missing mandatory block") if block.nil?

      if pipeline.empty?
        block.call(io_stream)
      elsif pipeline.size == 1
        stream, opts = pipeline.first
        open_stream(type, stream, io_stream, opts, display_name: display_name, &block)
      else
        # Daisy chain multiple streams together
        last = pipeline.keys.inject(block) do |inner, stream_sym|
          ->(io) { open_stream(type, stream_sym, io, pipeline[stream_sym], display_name: display_name, &inner) }
        end
        last.call(io_stream)
      end
    end

    # Asks the stream's format to open its reader or writer, see `IOStreams::StreamFormat#open_stream`.
    def open_stream(type, stream, io_stream, opts, display_name: nil, &)
      stream_format(stream).open_stream(
        type, io_stream, opts, name: stream, file_name: file_name, display_name: display_name, &
      )
    end
  end
end
