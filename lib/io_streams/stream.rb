# frozen_string_literal: true

module IOStreams
  class Stream
    # Why a copy with `convert: false` cannot accept options.
    UNCONVERTED_COPY = "with `convert: false`, which copies the data as-is"

    # The modes that a copy converts the data with, see #copy_from. Without a mode it copies the bytes.
    COPY_MODES = %i[line array hash].freeze

    # The deprecation warning of #format_options and #format_options=.
    FORMAT_OPTIONS_DEPRECATION = "#format_options is deprecated, use #schema instead, which gives the width of each " \
                                 "field of a fixed width file"

    # An example of setting each of the settings of rows and records that describe the file on the path, rather than
    # supplying it to each call of a reader or writer, which raises, see `IOStreams::Tabular::FORMAT_OPTION_NAMES`.
    PATH_SETTINGS = {
      format:             "path.format(:json).each(:hash)",
      default_format:     "path.format(:json).each(:hash)",
      file_name:          "path.file_name(\"data.json\").each(:hash)",
      format_options:     "path.schema(\"layout.json\").each(:hash)",
      schema:             "path.schema(\"people.json\").each(:hash)",
      row_format_options: "path.option(:parquet, compression: \"zstd\").writer(:hash)"
    }.freeze

    attr_reader :io_stream

    # Returns [Array<Symbol>] the options that only the readers of lines, rows and records accept, so that a writer, and
    # a copy, which uses its options to write its target, raise for them, rather than ignore them. Each reader and
    # writer declares the options that it accepts.
    def self.read_option_names
      @read_option_names ||= [
        [IOStreams::Line::Reader, IOStreams::Line::Writer],
        [IOStreams::Row::Reader, IOStreams::Row::Writer],
        [IOStreams::Record::Reader, IOStreams::Record::Writer]
      ].flat_map { |reader, writer| reader.option_names - writer.option_names }.uniq.freeze
    end

    # Returns [Module|nil] the format of the rows of the tabular format of the supplied name, such as `IOStreams::Parquet`
    # for `:parquet`, see `IOStreams::Tabular.row_format`, when #option and #stream set the options of its rows, which
    # the tabular settings hold, see `IOStreams::Tabular::Settings`, rather than the options of a stream. Returns nil for
    # any other name, including that of a stream, which takes precedence, see `IOStreams::Builder.stream_name?`, so that
    # the options of a registered extension of the same name still reach its stream.
    def self.row_format(name)
      name = name.to_sym if name.is_a?(String)
      return unless name.is_a?(Symbol)

      IOStreams::Tabular.row_format(name) unless IOStreams::Builder.stream_name?(name)
    end

    # Returns [Module|nil] the format whose options #option and #stream set for the supplied name, which decides which of
    # them are sensitive, see `IOStreams::StreamFormat#redact_options`: the format of a stream, such as `IOStreams::Gzip`
    # for `:gz`, see `IOStreams::Builder.find_format`, otherwise the format of the rows of a tabular format, such as
    # `IOStreams::Parquet` for `:parquet`, see .row_format, or nil when no format has the name.
    def self.stream_format(name)
      IOStreams::Builder.find_format(name) || row_format(name)
    end

    def initialize(io_stream)
      raise(ArgumentError, "io_stream cannot be nil") if io_stream.nil?
      if Utils.file_name?(io_stream)
        raise(ArgumentError, "io_stream must be an IO, not the name of a file: #{io_stream.inspect}, see IOStreams.path")
      end

      @io_stream = io_stream
      clear_configuration
    end

    # A copy has its own streams, options and tabular settings, so that changing them does not change the original, see
    # `IOStreams::Tabular::Settings#initialize_copy`.
    def initialize_copy(source)
      super
      @builder          = @builder&.dup
      @tabular_settings = @tabular_settings&.dup
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
    #
    # The options of the rows of a tabular format whose rows are not lines of text, such as Parquet, are set as with
    # #option, see .row_format, since its rows are not a stream, so they do not stop the streams being taken from the
    # file name.
    def stream(stream, **options)
      raise_if_frozen!
      if self.class.row_format(stream)
        tabular_settings.merge_row_options(stream, options)
      else
        builder.stream(stream, **options)
      end
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
    #
    # The options of a tabular format whose rows are not lines of text, such as Parquet, apply when its rows or records
    # are read or written, see `IOStreams::Tabular#read_rows`, whether the format is set with #format or detected from
    # the file name. They describe its rows rather than a stream, see .row_format, so they need no file name, can be
    # combined with #stream, and are kept by #raw, which only changes how the bytes are stored:
    #
    # IOStreams.path("people.parquet").schema("people.json").option(:parquet, compression: "zstd").writer(:hash)
    def option(stream, **options)
      raise_if_frozen!
      if self.class.row_format(stream)
        tabular_settings.merge_row_options(stream, options)
      else
        builder.option(stream, **options)
      end
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
    #
    # Without any arguments, returns [String|Encoding|nil] the encoding that was set, or nil when none was, like
    # `IO#encoding`.
    def encoding(encoding = nil, **options)
      return builder.setting(:encode)&.[](:encoding) if encoding.nil? && options.empty?

      raise_if_frozen!
      builder.encoding(encoding, **options)
      self
    end

    # Returns [true|false] whether the data is read and written as it is stored, see #raw.
    def raw?
      builder.raw?
    end

    # Adds the options for the specified stream as an option,
    # but if streams have already been added it is instead added as a stream.
    def option_or_stream(stream, **options)
      raise_if_frozen!
      if self.class.row_format(stream)
        tabular_settings.merge_row_options(stream, options)
      else
        builder.option_or_stream(stream, **options)
      end
      self
    end

    # Return the options already set for either a stream or option.
    def setting(stream)
      return tabular_settings.row_options(stream) if self.class.row_format(stream)

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
    #   lines: set the format with #format instead. It reports a deprecation warning, see `IOStreams::Deprecation`.
    # - The settings that describe the file, such as #format and #schema, are set on the path, and raise
    #   ArgumentError when they are supplied to a call, see PATH_SETTINGS. So does any other option that the mode does
    #   not take, before the file is opened, see `IOStreams::Line::Reader.option_names`,
    #   `IOStreams::Row::Reader.option_names` and `IOStreams::Record::Reader.option_names`.
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
      require_block!(:each, block, "To collect every #{mode}, call it with a block that adds each one to an Array.")

      reader(mode, **args) { |stream| stream.each(&block) }
    end

    # Returns a Reader for reading a file / stream
    #
    # The `:stream` mode reads bytes, so for example `read(1024)` on the stream it yields returns binary data, unless
    # an encode stream is set. The `:line`, `:array` and `:hash` modes read UTF-8 text, see #each.
    def reader(mode = :stream, **args, &block)
      require_block!(:reader, block)
      case mode
      when :stream
        reject_stream_mode_options!(args)
        stream_reader(&block)
      when :line
        line_reader(**args, &block)
      when :array
        row_reader(**args, &block)
      when :hash
        record_reader(**args, &block)
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
    # With a length, such as `read(1024)`, returns up to that number of bytes, which are binary, unless an encoding is
    # set, when it returns whole characters, which can be a few bytes more or fewer than the length.
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
    def writer(mode = :stream, **args, &block)
      require_block!(:writer, block)
      case mode
      when :stream
        reject_stream_mode_options!(args)
        open_writer(&block)
      when :line
        line_writer(**args, &block)
      when :array
        row_writer(**args, &block)
      when :hash
        record_writer(**args, &block)
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
      unless mode.nil? || COPY_MODES.include?(mode)
        raise(ArgumentError, "Invalid mode: #{mode.inspect}. A copy converts lines, rows or records with mode: " \
                             "#{COPY_MODES.map(&:inspect).join(', ')}, or copies the data, as bytes, without a mode")
      end

      if convert
        stream = to_stream(source)
        if mode
          reject_read_options!(
            args, "but a copy uses its options to write the target", suggest_schema: %i[array hash].include?(mode)
          )
          reject_unknown_options!(mode, mode_writer(mode), args)
          stream.reader(mode) do |rows|
            writer(mode, **args) { |target| rows.copy_to(target) }
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
    # Returns [Symbol] the format that was set, otherwise the format of the text that the stream closest to the
    # application reads and writes, when that stream decides it, such as `:csv` for a spreadsheet, whose cells are read
    # and written as CSV, otherwise the format detected from the file name, or [nil] when none applies.
    #
    # Reading or writing rows, records or lines raises ArgumentError when the format that was set is not the format of
    # the text of that stream, such as `:json` for a spreadsheet, rather than read or write them in the wrong format.
    def format(format = :none)
      if format == :none
        tabular_settings.format(file_name) { builder.text_format }
      else
        self.format = format
        self
      end
    end

    # Set the tabular format, such as `:json`, or the name of one, such as "json", for a format held in configuration.
    #
    # Raises ArgumentError for a format that is not registered, see `IOStreams::Tabular.registered_formats`.
    def format=(format)
      raise_if_frozen!
      tabular_settings.format = format
    end

    # Deprecated: use #schema, which gives the width of each field of a fixed width file, see docs/formats.md.
    # Reports a deprecation warning, see `IOStreams::Deprecation`.
    #
    # Set/get the layout of a fixed width file, `layout:` and `truncate:`, which are translated into the schema,
    # see `IOStreams::Tabular::Parser::Fixed.schema`, so that #schema returns the schema of the layout. The layout is
    # translated each time that it is read or written, as it was before it was deprecated, so that #schema and the
    # file read always agree with the layout, even when it is changed after it is set.
    def format_options(format_options = :none)
      if format_options == :none
        Deprecation.warn(FORMAT_OPTIONS_DEPRECATION)
        tabular_settings.format_options
      else
        self.format_options = format_options
        self
      end
    end

    # Deprecated: use #schema=, see #format_options.
    #
    # A layout replaces the schema. Empty format options are no layout, so they keep a schema set with #schema.
    #
    # Raises `IOStreams::Errors::InvalidLayout` when the layout is not valid, as soon as it is set, rather than when the
    # file is read, see `IOStreams::Tabular::Settings#format_options=`.
    def format_options=(format_options)
      raise_if_frozen!
      tabular_settings.format_options = format_options
      Deprecation.warn(FORMAT_OPTIONS_DEPRECATION)
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
    # Returns [Hash|String|IOStreams::Path] the schema as it was set, which is frozen, so that changing the object that
    # was supplied afterwards does not change it, or the schema of the layout set with the deprecated #format_options,
    # or [nil] when neither was set.
    #
    # Examples:
    #
    #   # people.csv has other columns too, such as "name", which the schema skips.
    #   path = IOStreams.path("people.csv").schema(fieldsMatch: "partial", fields: [{name: "age", type: "integer"}])
    #   path.each(:hash) do |person|
    #     person["age"] # => 42
    #   end
    #
    #   path = IOStreams.path("s3://bucket/people.txt").format(:fixed).schema("s3://bucket/schemas/people.json")
    #   path.each(:hash) { |person| p person }
    def schema(schema = :none)
      if schema == :none
        tabular_settings.schema
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
      tabular_settings.schema = schema
    end

    # Freezes this stream, so that the methods that set its streams, options, file name, format and schema raise
    # FrozenError, see `IOStreams.add_root`, and so does changing the Hashes that `#setting`, `#pipeline`,
    # `#format_options` and `#schema` return. The builder is created first, if it was not already, so that a frozen
    # stream can still be read and written. A stream without tabular settings needs none to be read, see
    # #tabular_settings.
    def freeze
      builder.freeze
      @tabular_settings&.freeze
      super
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
    #   IOStreams.path("foo.").extname            #=> "."
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
    # An empty string is also returned when the period is the last character in the `path`.
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

    # Clears the streams and options, see `IOStreams::Builder`, and the format, format options, schema and the options of
    # the rows, see `IOStreams::Tabular::Settings`, for example `#join` and `#directory` clear them on a copy of a path,
    # since they were set for the file of the original path. A new stream or path starts with none.
    def clear_configuration
      self.builder      = nil
      @tabular_settings = nil
    end

    # Options are strict: raise rather than ignore options that a copy cannot use, whatever their value, apart from a
    # `mode:` of nil, which is the same as not supplying it.
    def reject_copy_options!(reason, **options)
      names = options.keys
      names.delete(:mode) if options[:mode].nil?
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
      open_writer(&)
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

    # Raises ArgumentError for a setting that describes the file, see `IOStreams::Tabular::FORMAT_OPTION_NAMES`, since it
    # is set on the path, with an example of setting it there, see PATH_SETTINGS.
    def reject_path_settings!(options)
      names = IOStreams::Tabular::FORMAT_OPTION_NAMES & options.keys
      return if names.empty?

      messages = names.map do |name|
        "#{name.inspect} cannot be supplied to each call, set it on the path instead, for example: #{PATH_SETTINGS.fetch(name)}"
      end
      raise(ArgumentError, messages.join(". "))
    end

    # Options are strict: raise rather than ignore an option of a call in the mode that its reader or writer, the
    # supplied class, does not take, see the `option_names` of `IOStreams::Row::Reader` and the others, before anything
    # is opened. A setting that describes the file raises first, see #reject_path_settings!, with an example of setting
    # it on the path.
    def reject_unknown_options!(mode, klass, options)
      reject_path_settings!(options)
      unknown = options.keys - klass.option_names
      return if unknown.empty?

      raise(ArgumentError, "Unknown #{unknown.size == 1 ? 'option' : 'options'} #{unknown.map(&:inspect).join(', ')} for " \
                           "the #{mode.inspect} mode. Valid options: #{klass.option_names.map(&:inspect).join(', ')}.")
    end

    # Returns [Class] the writer of the mode, whose `option_names` are the options of each call that writes in it.
    def mode_writer(mode)
      case mode
      when :line then IOStreams::Line::Writer
      when :array then IOStreams::Row::Writer
      when :hash then IOStreams::Record::Writer
      end
    end

    # Raises ArgumentError for an option that only applies when reading, see .read_option_names, since writing would
    # ignore it.
    #
    # Suggests a schema in place of a column restriction when `suggest_schema`, for the modes that have columns.
    def reject_read_options!(options, reason, suggest_schema: true)
      names = self.class.read_option_names & options.keys
      return if names.empty?

      message = "#{names.map(&:inspect).join(', ')} only #{names.size == 1 ? 'applies' : 'apply'} when reading, #{reason}"
      if suggest_schema && names.intersect?(IOStreams::Tabular::Header::READ_OPTION_NAMES)
        message << ". To choose the columns that are written, set a schema on the path, whose fields are the columns"
      end
      raise(ArgumentError, message)
    end

    # Raises ArgumentError when no block is supplied, rather than open the file and raise from within the streams,
    # which would replace an existing file before raising, since a file is only open within the block.
    def require_block!(method, block, hint = nil)
      return if block

      message = "##{method} requires a block, so that the file is closed once it has been " \
                "#{method == :writer ? 'written' : 'read'}."
      raise(ArgumentError, hint ? "#{message} #{hint}" : message)
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

    # Returns [IOStreams::Tabular::Settings] the settings that describe the rows and records of this stream, such as the
    # options of the rows of a Parquet file, see #option. They are created when first needed, so that a stream that only
    # reads or writes bytes does not load `IOStreams::Tabular`. A frozen stream without any, see #freeze, has settings
    # that describe nothing, which it does not hold.
    def tabular_settings
      return @tabular_settings if @tabular_settings
      return IOStreams::Tabular::Settings.new.freeze if frozen?

      @tabular_settings = IOStreams::Tabular::Settings.new
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
      reject_unknown_options!(:line, IOStreams::Line::Reader, args)
      format = rows_format
      reject_unlined_format!(format)
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
    # a quoted CSV value stays within its row, including when CSV is the default format. They are read in blocks of
    # `buffer_size` bytes, when it is supplied, as in the `:line` mode.
    #
    # The other options, such as `cleanse_header:` and `columns:`, are those of the tabular that reads the rows, see
    # `IOStreams::Tabular.new`.
    def row_reader(delimiter: nil, embedded_within: :auto, buffer_size: nil, **args)
      reject_unknown_options!(:array, IOStreams::Row::Reader, args)
      tabular = tabular(**args)
      open_rows_reader(tabular, delimiter, embedded_within, buffer_size) do |io|
        yield IOStreams::Row::Reader.new(io, tabular: tabular)
      end
    end

    # Iterate over a file / stream returning each line as a hash, one at a time.
    #
    # The lines are split where the format that parses them expects, see #row_reader.
    def record_reader(delimiter: nil, embedded_within: :auto, buffer_size: nil, **args)
      reject_unknown_options!(:hash, IOStreams::Record::Reader, args)
      tabular = tabular(**args)
      open_rows_reader(tabular, delimiter, embedded_within, buffer_size) do |io|
        yield IOStreams::Record::Reader.new(io, tabular: tabular)
      end
    end

    # Yields [#each] the rows of the format of the tabular: its lines, split where the format expects, or the rows of a
    # format that holds them in a binary layout of its own, such as Parquet, read from its bytes, see
    # `IOStreams::Tabular#read_rows`.
    #
    # The line reader reads in blocks of `buffer_size` bytes, or of its own default when it is nil.
    #
    # Raises ArgumentError when `delimiter`, `embedded_within` or `buffer_size` is supplied, or an encoding is set, for a
    # format without lines, see #reject_line_options!.
    def open_rows_reader(tabular, delimiter, embedded_within, buffer_size, &)
      unless tabular.lines?
        reject_line_options!(tabular, delimiter: delimiter, embedded_within: (embedded_within unless embedded_within == :auto),
                                      buffer_size: buffer_size)
        return stream_reader { |io| tabular.read_rows(io, &) }
      end

      if embedded_within == :auto
        embedded_within = tabular.quote_character
      else
        Deprecation.warn("embedded_within: is deprecated when reading rows and records, since the format of the file " \
                         "splits their lines, set it with #format instead")
      end
      open_line_reader(tabular.encoding, delimiter: delimiter, embedded_within: embedded_within, buffer_size: buffer_size, &)
    end

    # Yields [#<<] the writer of the rows of the format of the tabular: a line writer, or the writer of a format that
    # holds its rows in a binary layout of its own, such as Parquet, see `IOStreams::Tabular#write_rows`.
    #
    # Raises ArgumentError when `delimiter` is supplied, or an encoding is set, for a format without lines, see
    # #reject_line_options!. Raises before the output is opened when the format cannot write the rows, such as without a
    # schema for Parquet, see `IOStreams::Tabular#check_write_rows`, so that an existing file is not replaced.
    def open_rows_writer(tabular, delimiter, &)
      unless tabular.lines?
        reject_line_options!(tabular, delimiter: delimiter)
        tabular.check_write_rows
        return open_writer { |io| tabular.write_rows(io, &) }
      end

      IOStreams::Line::Writer.check(delimiter: delimiter)
      open_line_writer(tabular.encoding, delimiter: delimiter, &)
    end

    # Options are strict: raise rather than ignore the options of lines for a format whose rows are not lines, and
    # an encoding, see #encoding, since its rows are not text, so that the encode stream would only change its bytes.
    def reject_line_options!(tabular, **options)
      names = options.compact.keys
      unless names.empty?
        raise(ArgumentError, "#{names.map(&:inspect).join(', ')} cannot be used with the #{tabular.format.inspect} " \
                             "format, whose rows are not lines of text")
      end
      return unless builder.setting(:encode)

      raise(ArgumentError, "#encoding cannot be used with the #{tabular.format.inspect} format, whose rows are not " \
                           "text, so that an encoding would only change the bytes of the file")
    end

    # Raises ArgumentError for the `:line` mode of a format whose rows are not lines of text, such as Parquet.
    def reject_unlined_format!(format)
      return if IOStreams::Tabular.lines?(format)

      raise(ArgumentError, "The #{format.inspect} format has no lines, so read and write its rows with the :array or " \
                           ":hash mode, or its bytes with the :stream mode")
    end

    # Returns [IOStreams::Tabular] that reads or writes the rows of this stream with the options of the call, which have
    # been checked, see #reject_unknown_options!, as its tabular settings describe them, see
    # `IOStreams::Tabular::Settings#tabular`.
    def tabular(**)
      tabular_settings.tabular(file_name: file_name, text_format: builder.text_format, **)
    end

    # Returns [Symbol|nil] the format of the rows, records and lines of this stream, see #format.
    #
    # Raises ArgumentError when the format set with #format is not the format of the text that the stream closest to the
    # application reads and writes, see `IOStreams::Tabular::Settings#rows_format`.
    def rows_format
      tabular_settings.rows_format(file_name, builder.text_format)
    end

    def stream_writer(&)
      builder.writer(io_stream, &)
    end

    # Yields the stream that writes the data through the streams, see #stream_writer, once each stream has checked its
    # options, see `IOStreams::Builder#check_writer`, so that a value that a stream cannot write with, such as a gzip
    # level of 99, raises before a path opens its output, which would replace an existing file.
    def open_writer(&)
      builder.check_writer
      stream_writer(&)
    end

    # The lines are written in the encoding of the format, see #line_reader.
    def line_writer(**args, &block)
      reject_read_options!(args, "not when writing", suggest_schema: false)
      reject_unknown_options!(:line, IOStreams::Line::Writer, args)
      return block.call(io_stream) if open_writer_supplied?(IOStreams::Line::Writer, args)

      format = rows_format
      reject_unlined_format!(format)
      IOStreams::Line::Writer.check(**args)
      open_line_writer(IOStreams::Tabular.encoding(format), **args, &block)
    end

    # Yields a line writer of the text written in the supplied encoding, unless an encoding is set on the encode
    # stream. When the encoding is nil the text is written as it is, unless the encode stream is set.
    #
    # A line writer supplied to `IOStreams.stream` writes the rows and records of the format of this stream, see
    # #open_rows_writer, in its own lines.
    def open_line_writer(encoding, **args, &block)
      return block.call(io_stream) if open_writer_supplied?(IOStreams::Line::Writer, args, format_applies: true)

      with_default_encoding(encoding).text_writer do |io|
        IOStreams::Line::Writer.stream(io, **args, &block)
      end
    end

    # Returns [true|false] whether the IO of this stream is already a writer of the supplied class, such as a line
    # writer handed to code that writes lines with `IOStreams.stream(io).writer(:line)`, which then writes into it.
    #
    # Raises ArgumentError when anything is supplied or set that the open writer cannot apply, since it writes with its
    # own settings: options of the call, streams, an encoding or a file name that implies streams, and, unless
    # `format_applies`, a format or a schema.
    def open_writer_supplied?(klass, options, format_applies: false)
      return false unless io_stream.is_a?(klass)

      names  = options.compact.keys.map(&:inspect)
      names << "#stream, #option or #encoding" unless builder.pipeline.empty?
      names << "#format, #schema or #format_options" unless format_applies || !tabular_settings.described?
      return true if names.empty?

      raise(ArgumentError, "#{names.join(', ')} cannot be applied to the #{klass.name} supplied to IOStreams.stream, " \
                           "which is already open, and writes with its own settings")
    end

    # The delimiter is the default of the line writer unless it is supplied, see #open_rows_writer. The writer of the rows
    # finishes once the block returns, see `IOStreams::Row::Writer#finish`.
    def row_writer(delimiter: nil, **args, &block)
      reject_read_options!(args, "not when writing")
      reject_unknown_options!(:array, IOStreams::Row::Writer, args)
      return block.call(io_stream) if open_writer_supplied?(IOStreams::Row::Writer, {delimiter: delimiter, **args})

      tabular = tabular(**args)
      open_rows_writer(tabular, delimiter) do |io|
        rows = IOStreams::Row::Writer.new(io, tabular: tabular)
        IOStreams::Utils.finish_or_abort(finish: -> { rows.finish }) { block.call(rows) }
      end
    end

    # The delimiter is the default of the line writer unless it is supplied, see #open_rows_writer.
    def record_writer(delimiter: nil, **args, &block)
      reject_read_options!(args, "not when writing")
      reject_unknown_options!(:hash, IOStreams::Record::Writer, args)
      return block.call(io_stream) if open_writer_supplied?(IOStreams::Record::Writer, {delimiter: delimiter, **args})

      tabular = tabular(**args)
      open_rows_writer(tabular, delimiter) do |io|
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
