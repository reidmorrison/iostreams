# frozen_string_literal: true

module IOStreams
  class Stream
    # Why a copy with `convert: false` cannot accept options.
    UNCONVERTED_COPY = "with `convert: false`, which copies the data as-is"

    # The settings of rows and records that describe the file, so that they are set on the path, rather than supplied
    # to each call of a reader or writer, with an example of setting each one.
    PATH_SETTINGS = {
      format:         "path.format(:json).each(:hash)",
      default_format: "path.format(:json).each(:hash)",
      file_name:      "path.file_name(\"data.json\").each(:hash)",
      format_options: "path.schema(\"layout.json\").each(:hash)",
      schema:         "path.schema(\"people.json\").each(:hash)"
    }.freeze

    # The options that only apply when reading, so that a writer, and a copy, which uses its options to write its
    # target, raise for them, rather than ignore them.
    READ_OPTIONS = %i[cleanse_header allowed_columns required_columns skip_unknown embedded_within buffer_size].freeze

    attr_reader :io_stream

    def initialize(io_stream)
      raise(ArgumentError, "io_stream cannot be nil") if io_stream.nil?
      raise(ArgumentError, "io_stream must not be a string: #{io_stream.inspect}") if io_stream.is_a?(String)

      @io_stream      = io_stream
      @builder        = nil
      @format         = nil
      @format_options = nil
      @schema         = nil
      @schema_source  = nil
    end

    # A copy has its own streams and options, so that changing them does not change the original.
    # It shares the source of the schema, which does not change, so that a schema file is read once.
    def initialize_copy(source)
      super
      @builder        = @builder&.dup
      @format_options = @format_options&.dup
      @schema         = @schema.dup if @schema.is_a?(Hash)
    end

    # Ignore the filename and use only the supplied streams.
    #
    # See #option to set an option for one of the streams included based on the file name extensions.
    #
    # Supplying `:none` to apply no streams is deprecated. Use #raw to read or write the data as it is stored,
    # or set the file name with #file_name when the file is not named for its format.
    #
    # Example:
    #
    # IOStreams.path("tempfile2527").stream(:zip).stream(:pgp, passphrase: "receiver_passphrase").read
    def stream(stream, **)
      raise_if_frozen!
      builder.stream(stream, **)
      self
    end

    # Set the options for an element within the stream for this file.
    # If the relevant stream is not found for this file it is ignored.
    # For example, if the file does not have a pgp extension then the pgp option is not relevant.
    # An option for a format applies to each of its extensions, such as the pgp option to a `.gpg` file.
    #
    # IOStreams.path("keep_safe.pgp").option(:pgp, passphrase: "receiver_passphrase").read
    #
    # # The same option applies to a `.gpg` file, since it is a PGP file too.
    # IOStreams.path("keep_safe.gpg").option(:pgp, passphrase: "receiver_passphrase").read
    #
    # # In this case the file is not pgp so the `passphrase` option is ignored.
    # IOStreams.path("keep_safe.enc").option(:pgp, passphrase: "receiver_passphrase").read
    #
    # IOStreams.path(output_file_name).option(:pgp, passphrase: "receiver_passphrase").read
    #
    # Setting the encode stream with `option(:encode, ...)` is deprecated, use #encoding instead.
    def option(stream, **)
      raise_if_frozen!
      builder.option(stream, **)
      self
    end

    # Read and write the data as it is stored: no streams are applied, neither those that the file name implies
    # nor any set with #stream or #option, and no encoding, so text is read and written as bytes.
    # Setting a stream, option or encoding afterwards raises ArgumentError.
    #
    # Examples:
    #
    # # Checksum a compressed file as it is stored.
    # Digest::SHA256.hexdigest(IOStreams.path("data.csv.gz").raw.read)
    #
    # # Write data that is already compressed.
    # IOStreams.path("data.csv.gz").raw.write(gzipped_data)
    #
    # To copy a file as it is stored, such as downloading a zip file without unzipping it, use
    # `copy_to(target, convert: false)`, since the target applies its own streams. To read a file that is not named
    # for its format, such as a CSV file called `data.txt`, set the file name that names its format instead, for
    # example `file_name("data.csv")`.
    #
    # Replaces `stream(:none)`, which still works, but keeps the default encoding of the text, see #encoding.
    def raw
      raise_if_frozen!
      builder.raw
      self
    end

    # Set the character encoding of the text that the application reads or writes, which the built-in encode
    # stream converts, and its other options, `replace:` and `cleaner:`. Unlike the streams in the file name, the
    # encoding stays with the path, whichever streams it has, and works for a stream without a file name too.
    #
    # Examples:
    #
    # # Read a Windows-1252 file as UTF-8 strings.
    # IOStreams.path("legacy.csv").encoding("Windows-1252:UTF-8").each(:hash) { |hash| p hash }
    #
    # # Read binary lines from a compressed file, which is still decompressed.
    # IOStreams.path("data.csv.gz").encoding("BINARY").each(:line) { |line| p line }
    #
    # # Replace invalid characters with "?" instead of raising.
    # IOStreams.path("export.csv").encoding("UTF-8", replace: "?").read
    #
    # Replaces `option(:encode, ...)` and `stream(:encode, ...)`, which still work.
    def encoding(encoding = nil, **)
      raise_if_frozen!
      builder.encoding(encoding, **)
      self
    end

    # Adds the options for the specified stream as an option,
    # but if streams have already been added it is instead added as a stream.
    def option_or_stream(stream, **)
      raise_if_frozen!
      builder.option_or_stream(stream, **)
      self
    end

    # Return the options already set for either a stream or option.
    def setting(stream)
      builder.setting(stream)
    end

    # Returns [Hash<Symbol:Hash>] the pipeline of streams
    # with their options that will be applied when the reader or writer is invoked.
    def pipeline
      builder.pipeline
    end

    # Removes the named stream from the current pipeline.
    # If the stream pipeline has not yet been built it will be built from the file_name if present.
    # Note: Any options must be set _before_ calling this method.
    def remove_from_pipeline(stream_name)
      raise_if_frozen!
      builder.remove_from_pipeline(stream_name)
      self
    end

    # Returns [true|false] whether a stream in the #pipeline compresses the data, such as `:gz` or `:zip`,
    # whether it was inferred from the file name or set with #stream.
    #
    # Compression within an encrypted stream, such as `:pgp` or `:enc`, is not reported, since only the
    # encrypted data records whether it was used.
    #
    # Example:
    #   IOStreams.path("data.csv.gz.pgp").compressed?
    #   # => true
    #
    #   IOStreams.path("tempfile2527").stream(:gz).compressed?
    #   # => true
    #
    #   IOStreams.path("data.csv.gz").raw.compressed?
    #   # => false
    def compressed?
      builder.compressed?
    end

    # Returns [true|false] whether a stream in the #pipeline encrypts the data, such as `:pgp` or `:enc`,
    # whether it was inferred from the file name or set with #stream.
    #
    # Example:
    #   IOStreams.path("data.csv.gz.pgp").encrypted?
    #   # => true
    def encrypted?
      builder.encrypted?
    end

    # Iterate over a file / stream returning one line at a time.
    #
    # Example: Read a line at a time
    #   IOStreams.path("file.txt").each(:line) do |line|
    #     puts line
    #   end
    #
    # Example: Read a line at a time with custom options
    #   IOStreams.path("file.csv").each(:line, embedded_within: '"') do |line|
    #     puts line
    #   end
    #
    # Example: Read a row at a time
    #   IOStreams.path("file.csv").each(:array) do |array|
    #     p array
    #   end
    #
    # Example: Read a record at a time
    #   IOStreams.path("file.csv").each(:hash) do |hash|
    #     p hash
    #   end
    #
    # Notes:
    # - Newlines embedded within quoted fields are kept within the same line when
    #   1. The tabular format quotes its fields, such as CSV, whether set explicitly via `.format(:csv)`,
    #      or detected from a `.csv` file name. Rows and records are read as CSV unless another format
    #      applies, so this includes `:array` and `:hash` for a file name without a tabular extension.
    #   2. Or, in the `:line` mode, the `embedded_within` argument is supplied (e.g. `embedded_within: '"'`).
    # - Pass `embedded_within: nil` to read the physical lines of a quoted format in the `:line` mode.
    #   Supplying `embedded_within` in the `:array` and `:hash` modes is deprecated, since the format splits their
    #   lines: set the format with #format instead.
    # - The settings that describe the file, such as #format and #schema, are set on the path, and raise
    #   ArgumentError when they are supplied to a call, see PATH_SETTINGS.
    # - Lines, rows and records are read as UTF-8 text, and data that is not valid UTF-8 raises
    #   `IOStreams::Errors::InvalidEncoding`, an `Encoding::UndefinedConversionError`, with the byte offset and line
    #   number of the invalid data, once the lines before it have been read. To read text in another encoding,
    #   set it with #encoding, for example `encoding("ISO-8859-1")`, or `encoding("BINARY")` to read binary lines.
    #   See also its `replace:` option.
    def each(mode = :line, **args, &block)
      raise(ArgumentError, "Invalid mode: #{mode.inspect}") if mode == :stream

      # Deliberately not returning an Enumerator when no block is given.
      # The stream pipeline manages resources via block scope: every stream is opened with an
      # `ensure` that closes the file handle, reaps the gpg subprocess, deletes temp files, etc.
      # A Fiber-backed Enumerator (e.g. `to_enum(__method__, mode, **args)`) would leave that block
      # suspended; if the caller abandons a partially-consumed enumerator, none of the cleanup runs
      # until GC collects the Fiber, leaking file descriptors, gpg processes, and temp files.
      unless block
        raise(ArgumentError, "#each requires a block, so that the file is closed once it has been read. " \
                             "To collect every #{mode}, call it with a block that adds each one to an Array.")
      end

      reader(mode, **args) { |stream| stream.each(&block) }
    end

    # Returns a Reader for reading a file / stream
    #
    # The `:stream` mode reads bytes, so for example `read(1024)` on the stream it yields returns binary data, unless
    # an encode stream is set. The `:line`, `:array` and `:hash` modes read UTF-8 text, see #each.
    def reader(mode = :stream, **args, &)
      case mode
      when :stream
        reject_stream_mode_options!(args)
        stream_reader(&)
      when :line
        line_reader(**args, &)
      when :array
        row_reader(**args, &)
      when :hash
        record_reader(**args, &)
      else
        raise(ArgumentError, "Invalid mode: #{mode.inspect}")
      end
    end

    # Read an entire file into memory.
    #
    # Returns [String] the whole file as UTF-8, like `File.read`, without checking that it is valid UTF-8, so that a
    # binary file can be read too, since its bytes are unchanged. An encoding set with #encoding returns the data
    # in that encoding instead, and checks it, for example `encoding("UTF-8")`. Reading an IO
    # that you supplied, without any streams, keeps the encoding that the IO gives its data.
    #
    # With a length, such as `read(1024)`, returns up to that number of bytes, which are binary unless an encoding
    # is set.
    #
    # Notes:
    # - Use with caution since large files can cause a denial of service since
    #   this method will load the entire file into memory.
    # - Recommend using instead `#reader` to read a block into memory at a time.
    def read(*args)
      data = reader { |stream| stream.read(*args) }
      args.first.nil? ? builder.text(data) : data
    end

    # Returns a Writer for writing to a file / stream
    def writer(mode = :stream, **args, &)
      case mode
      when :stream
        reject_stream_mode_options!(args)
        stream_writer(&)
      when :line
        line_writer(**args, &)
      when :array
        row_writer(**args, &)
      when :hash
        record_writer(**args, &)
      else
        raise(ArgumentError, "Invalid mode: #{mode.inspect}")
      end
    end

    # Write entire string to file.
    #
    # Notes:
    # - Use with caution since preparing large amounts of data in memory can cause a denial of service
    #   since all the data for the file needs to be resident in memory before writing.
    # - Recommend using instead `#writer` to write a block of memory at a time.
    def write(data)
      writer { |stream| stream.write(data) }
    end

    # Copy from another stream, path, file_name or IO instance.
    #
    # Parameters:
    #   stream [IOStreams::Path|String<file_name>|IO]
    #     The stream to read from.
    #
    #   :convert [true|false]
    #     Whether to apply the stream conversions during the copy.
    #     Default: true
    #
    #   :mode [:line, :array, :hash]
    #     When convert is `true` then use this mode to convert the contents of the file.
    #
    #   Any other options are passed to the writer for the `mode`, see `#writer`. Without a `mode`,
    #   or with `convert: false`, no other options are accepted.
    #
    # Examples:
    #
    # # Copy and convert streams based on file extensions
    # IOStreams.path("target_file.json").copy_from("source_file_name.csv.gz")
    #
    # # Copy "as-is" without any automated stream conversions
    # IOStreams.path("target_file.json").copy_from("source_file_name.csv.gz", convert: false)
    #
    # # Advanced copy with custom stream conversions on source and target.
    # source = IOStreams.path("source_file").encoding("BINARY")
    # IOStreams.path("target_file.pgp").option(:pgp, passphrase: "hello").copy_from(source)
    #
    # Returns [Integer] the number of bytes copied, when copying without a `mode:`.
    #
    # Notes:
    # - The source is opened before the target, so that the target is not changed when the source
    #   cannot be read, for example when it does not exist.
    def copy_from(source, convert: true, mode: nil, **args)
      if convert
        stream = to_stream(source)
        if mode
          reject_read_options!(
            args, "but a copy uses its options to write the target", suggest_schema: %i[array hash].include?(mode)
          )
          stream.reader(mode) do |rows|
            writer(mode, **args) do |target|
              rows.each { |row| target << row }
            end
          end
        else
          reject_copy_options!("when copying without a `mode:`", **args)
          stream.reader do |src|
            writer { |target| IO.copy_stream(src, target) }
          end
        end
      else
        reject_copy_options!(UNCONVERTED_COPY, mode: mode, **args)
        to_stream(source).without_streams.reader do |src|
          without_streams.writer { |target| IO.copy_stream(src, target) }
        end
      end
    end

    def copy_to(target, **args)
      target = to_stream(target)
      target.copy_from(self, **args)
    end

    # Set/get the original file_name
    def file_name(file_name = :none)
      if file_name == :none
        builder.file_name
      else
        self.file_name = file_name
        self
      end
    end

    # Set the original file_name
    def file_name=(file_name)
      raise_if_frozen!
      builder.file_name = file_name
    end

    # Set/get the tabular format.
    #
    # Returns [Symbol] the format that was set, otherwise the format detected from the file name,
    # or [nil] when neither applies.
    def format(format = :none)
      if format == :none
        @format || IOStreams::Tabular.format_from_file_name(file_name)
      else
        self.format = format
        self
      end
    end

    # Set the tabular format
    def format=(format)
      unless format.nil? || IOStreams::Tabular.registered_formats.include?(format)
        raise(ArgumentError, "Invalid format: #{format.inspect}")
      end

      @format = format
    end

    # Deprecated: use #schema, which gives the width of each field of a fixed width file, see docs/formats.md.
    #
    # Set/get the layout of a fixed width file, `layout:` and `truncate:`, which are translated into the schema,
    # see `IOStreams::Tabular::Parser::Fixed.schema`, so that #schema returns the schema of the layout.
    def format_options(format_options = :none)
      if format_options == :none
        @format_options
      else
        self.format_options = format_options
        self
      end
    end

    # Deprecated: use #schema=, see #format_options.
    #
    # Raises `IOStreams::Errors::InvalidLayout` when the layout is not valid.
    def format_options=(format_options)
      raise_if_frozen!
      if format_options.nil? || format_options.empty?
        # Removes the schema of the layout set before, but not a schema set with #schema.
        self.schema = nil if @format_options
      else
        self.schema = IOStreams::Tabular::Parser::Fixed.schema(**format_options)
      end
      @format_options = format_options
    end

    # Set/get the schema of the rows and records of this file: the name and type of each field, so that reading
    # rows and records returns each value as its type, such as an Integer or a Date, and writing them writes each
    # value in the text form of its type. It applies to every tabular format, and gives the position of each field of
    # a fixed width file. See docs/formats.md, and `IOStreams::Schema` for its properties.
    #
    # Parameters:
    #   schema: [Hash|String|IOStreams::Path]
    #     A Frictionless Table Schema as a Hash, which is checked now, or the path or url of a JSON file that holds
    #     one, in any store, which is read the first time that a reader or writer needs it.
    #     nil removes the schema.
    #
    # Returns [Hash|String|IOStreams::Path] the schema that was set, or [nil] when none was set.
    #
    # Examples:
    #
    #   IOStreams.path("people.csv").schema(fields: [{name: "age", type: "integer"}]).each(:hash) do |person|
    #     person["age"] # => 42
    #   end
    #
    #   path = IOStreams.path("s3://bucket/people.txt").format(:fixed).schema("s3://bucket/schemas/people.json")
    #   path.each(:hash) { |person| p person }
    def schema(schema = :none)
      if schema == :none
        @schema
      else
        self.schema = schema
        self
      end
    end

    # Set the schema, see #schema.
    #
    # Raises ArgumentError when the schema is not a Hash, a String or a path, or is a Hash that is not a valid schema.
    def schema=(schema)
      raise_if_frozen!
      @schema_source  = schema.nil? ? nil : IOStreams::Schema::Source.new(schema)
      @schema         = schema
      @format_options = nil
    end

    # Returns [String] the last component of this path.
    # Returns `nil` if no `file_name` was set.
    #
    # Parameters:
    #   suffix: [String]
    #     When supplied the `suffix` is removed from the file_name before being returned.
    #     Use `.*` to remove any extension.
    #
    #   IOStreams.path("/home/gumby/work/ruby.rb").basename         #=> "ruby.rb"
    #   IOStreams.path("/home/gumby/work/ruby.rb").basename(".rb")  #=> "ruby"
    #   IOStreams.path("/home/gumby/work/ruby.rb").basename(".*")   #=> "ruby"
    def basename(suffix = nil)
      file_name = builder.file_name
      return unless file_name

      suffix.nil? ? ::File.basename(file_name) : ::File.basename(file_name, suffix)
    end

    # Returns [String] the directory for this file.
    # Returns `nil` if no `file_name` was set.
    #
    # If `path` does not include a directory name the "." is returned.
    #
    #   IOStreams.path("test.rb").dirname         #=> "."
    #   IOStreams.path("a/b/d/test.rb").dirname   #=> "a/b/d"
    #   IOStreams.path(".a/b/d/test.rb").dirname  #=> ".a/b/d"
    #   IOStreams.path("foo.").dirname            #=> "."
    #   IOStreams.path("test").dirname            #=> "."
    #   IOStreams.path(".profile").dirname        #=> "."
    def dirname
      file_name = builder.file_name
      ::File.dirname(file_name) if file_name
    end

    # Returns [String] the extension for this file including the last period.
    # Returns `nil` if no `file_name` was set.
    #
    # If `path` is a dotfile, or starts with a period, then the starting
    # dot is not considered part of the extension.
    #
    # An empty string will also be returned when the period is the last character in the `path`.
    #
    #   IOStreams.path("test.rb").extname         #=> ".rb"
    #   IOStreams.path("a/b/d/test.rb").extname   #=> ".rb"
    #   IOStreams.path(".a/b/d/test.rb").extname  #=> ".rb"
    #   IOStreams.path("foo.").extname            #=> ""
    #   IOStreams.path("test").extname            #=> ""
    #   IOStreams.path(".profile").extname        #=> ""
    #   IOStreams.path(".profile.sh").extname     #=> ".sh"
    def extname
      file_name = builder.file_name
      ::File.extname(file_name) if file_name
    end

    # Returns [String] the extension for this file _without_ the last period.
    # Returns `nil` if no `file_name` was set.
    #
    # If `path` is a dotfile, or starts with a period, then the starting
    # dot is not considered part of the extension.
    #
    # An empty string will also be returned when the period is the last character in the `path`.
    #
    #   IOStreams.path("test.rb").extension         #=> "rb"
    #   IOStreams.path("a/b/d/test.rb").extension   #=> "rb"
    #   IOStreams.path(".a/b/d/test.rb").extension  #=> "rb"
    #   IOStreams.path("foo.").extension            #=> ""
    #   IOStreams.path("test").extension            #=> ""
    #   IOStreams.path(".profile").extension        #=> ""
    #   IOStreams.path(".profile.sh").extension     #=> "sh"
    def extension
      extname&.delete_prefix(".")
    end

    protected

    # Replaces the streams and options. Not public, since a builder is internal.
    attr_writer :builder

    # Clears the streams, options, format, format options and schema, for example `#join` and `#directory`
    # clear them on a copy of a path, since they were set for the file of the original path.
    def clear_configuration
      self.builder    = nil
      @format         = nil
      @format_options = nil
      @schema         = nil
      @schema_source  = nil
    end

    # Options are strict: raise rather than ignore options that a copy cannot use.
    def reject_copy_options!(reason, **options)
      names = options.compact.keys
      return if names.empty?

      raise(ArgumentError, "#{names.map(&:inspect).join(', ')} cannot be used #{reason}")
    end

    # Yields a stream that reads the text read through the streams, decoded by the encode stream, see
    # `IOStreams::Builder#text_reader`. Protected, so that it can be called on a copy that reads in another encoding,
    # see #with_default_encoding.
    def text_reader(&)
      stream_reader { |io| builder.text_reader(io, &) }
    end

    # Yields a stream that writes text through the streams. Protected, see #text_reader.
    def text_writer(&)
      stream_writer(&)
    end

    # Returns [IOStreams::Stream] a copy of this stream that reads and writes its data as-is, without
    # changing the streams or options of this one.
    def without_streams
      copy         = dup
      copy.builder = IOStreams::Builder.new(file_name).raw
      copy
    end

    private

    # Returns [IOStreams::Stream] the supplied stream or path itself, otherwise a new one for the
    # file name or IO, so that a copy or move uses, and returns, the path the caller supplied.
    def to_stream(file_name_or_io)
      file_name_or_io.is_a?(Stream) ? file_name_or_io : IOStreams.new(file_name_or_io)
    end

    # Raises ArgumentError for a setting that describes the file, see PATH_SETTINGS, since it is set on the path.
    def reject_path_settings!(options)
      names = PATH_SETTINGS.keys & options.keys
      return if names.empty?

      messages = names.map do |name|
        "#{name.inspect} cannot be supplied to each call, set it on the path instead, for example: #{PATH_SETTINGS[name]}"
      end
      raise(ArgumentError, messages.join(". "))
    end

    # Raises ArgumentError for an option that only applies when reading, see READ_OPTIONS, since writing would ignore it.
    #
    # Suggests a schema in place of a column restriction when `suggest_schema`, for the modes that have columns.
    def reject_read_options!(options, reason, suggest_schema: true)
      names = READ_OPTIONS & options.keys
      return if names.empty?

      message = "#{names.map(&:inspect).join(', ')} only #{names.size == 1 ? 'applies' : 'apply'} when reading, #{reason}"
      if suggest_schema && names.intersect?(%i[allowed_columns required_columns skip_unknown])
        message << ". To choose the columns that are written, set a schema on the path, whose fields are the columns"
      end
      raise(ArgumentError, message)
    end

    # Options are strict: raise rather than ignore options that the :stream mode cannot use.
    def reject_stream_mode_options!(options)
      return if options.empty?

      names = options.keys.map(&:inspect).join(", ")
      raise(
        ArgumentError,
        "Unknown #{options.size == 1 ? 'option' : 'options'} for the :stream mode: #{names}. " \
        "Use #option or #stream to configure the streams."
      )
    end

    def builder
      @builder ||= IOStreams::Builder.new
    end

    # Raises [FrozenError] when this stream is frozen, since the methods that change its builder, such as
    # #option and #file_name=, would otherwise change it even though this stream is frozen,
    # see `IOStreams::Path#freeze`.
    def raise_if_frozen!
      raise(FrozenError.new("can't modify frozen #{self.class}: #{inspect}", receiver: self)) if frozen?
    end

    def stream_reader(&)
      builder.reader(io_stream, &)
    end

    # The lines are read in the encoding of the format, set with #format or detected from the file name, see
    # `IOStreams::Tabular#encoding`, unless an encoding is set on the encode stream.
    def line_reader(embedded_within: :auto, **args, &)
      reject_path_settings!(args)
      # `:auto` uses the quote character of the format, set with #format or detected from the file name,
      # such as `"` for CSV, while distinguishing "not supplied" from an explicit value such as `nil`
      # (disable) or `'"'` (force).
      embedded_within = IOStreams::Tabular.quote_character(format) if embedded_within == :auto

      open_line_reader(IOStreams::Tabular.encoding(format), embedded_within: embedded_within, **args, &)
    end

    # Yields a line reader of the text read in the supplied encoding, unless an encoding is set on the encode stream.
    def open_line_reader(encoding, **args)
      with_default_encoding(encoding).text_reader do |text|
        yield IOStreams::Line::Reader.new(text, **args)
      end
    end

    # Iterate over a file / stream returning each line as an array, one at a time.
    #
    # The lines are split where the format that parses them expects, so that for example a newline within
    # a quoted CSV value stays within its row, including when CSV is the default format.
    def row_reader(delimiter: nil, embedded_within: :auto, cleanse_header: IOStreams::Tabular::CLEANSE_BY_DEFAULT, **args)
      tabular         = tabular(**args)
      embedded_within = tabular.quote_character if embedded_within == :auto
      open_line_reader(tabular.encoding, delimiter: delimiter, embedded_within: embedded_within) do |io|
        yield IOStreams::Row::Reader.new(io, tabular: tabular, cleanse_header: cleanse_header)
      end
    end

    # Iterate over a file / stream returning each line as a hash, one at a time.
    #
    # The lines are split where the format that parses them expects, see #row_reader.
    def record_reader(delimiter: nil, embedded_within: :auto, cleanse_header: IOStreams::Tabular::CLEANSE_BY_DEFAULT, **args)
      tabular         = tabular(**args)
      embedded_within = tabular.quote_character if embedded_within == :auto
      open_line_reader(tabular.encoding, delimiter: delimiter, embedded_within: embedded_within) do |io|
        yield IOStreams::Record::Reader.new(io, tabular: tabular, cleanse_header: cleanse_header)
      end
    end

    # Returns [IOStreams::Tabular] that reads or writes the rows of this stream in the format set with #format,
    # otherwise the one detected from the file name, otherwise CSV, see `IOStreams::Tabular.new`, with the schema
    # set with #schema, reading its file the first time.
    #
    # The layout set with #format_options, which is deprecated, is supplied as the layout, so that the options of each
    # call that describe its columns, such as `columns:`, still apply to it as they did before. They raise with a
    # schema.
    def tabular(**args)
      reject_path_settings!(args)
      if @format_options
        IOStreams::Tabular.new(file_name: file_name, format: @format, format_options: @format_options, **args)
      else
        IOStreams::Tabular.new(file_name: file_name, format: @format, schema: @schema_source&.schema, **args)
      end
    end

    def stream_writer(&)
      builder.writer(io_stream, &)
    end

    # The lines are written in the encoding of the format, see #line_reader.
    def line_writer(**args, &block)
      reject_path_settings!(args)
      reject_read_options!(args, "not when writing", suggest_schema: false)
      return block.call(io_stream) if io_stream.is_a?(IOStreams::Line::Writer)

      open_line_writer(IOStreams::Tabular.encoding(format), **args, &block)
    end

    # Yields a line writer of the text written in the supplied encoding, unless an encoding is set on the encode
    # stream. When the encoding is nil the text is written as it is, unless the encode stream is set.
    def open_line_writer(encoding, **args, &block)
      return block.call(io_stream) if io_stream.is_a?(IOStreams::Line::Writer)

      with_default_encoding(encoding).text_writer do |io|
        IOStreams::Line::Writer.stream(io, **args, &block)
      end
    end

    def row_writer(delimiter: $/, **args, &block)
      reject_read_options!(args, "not when writing")
      return block.call(io_stream) if io_stream.is_a?(IOStreams::Row::Writer)

      tabular = tabular(**args)
      open_line_writer(tabular.encoding, delimiter: delimiter) do |io|
        block.call(IOStreams::Row::Writer.new(io, tabular: tabular))
      end
    end

    def record_writer(delimiter: $/, **args, &block)
      reject_read_options!(args, "not when writing")
      return block.call(io_stream) if io_stream.is_a?(IOStreams::Record::Writer)

      tabular = tabular(**args)
      open_line_writer(tabular.encoding, delimiter: delimiter) do |io|
        block.call(IOStreams::Record::Writer.new(io, tabular: tabular))
      end
    end

    # Returns [IOStreams::Stream] this stream, when the encoding is nil, otherwise a copy that reads and writes text
    # in the supplied encoding unless an encoding is set on the encode stream, see `IOStreams::Builder#with_default_encoding`.
    def with_default_encoding(encoding)
      return self if encoding.nil?

      copy         = dup
      copy.builder = builder.with_default_encoding(encoding)
      copy
    end
  end
end
