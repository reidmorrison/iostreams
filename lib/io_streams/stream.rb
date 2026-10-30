module IOStreams
  class Stream
    # How to set each setting of the file on the path instead, which the readers and writers of rows and records accept
    # for each call, see #path_setting_names, and v3.0 only accepts on the path. A file name supplied to a call only
    # chooses its format, when the path has none, and not its streams, as #file_name does, so the format replaces it.
    PATH_SETTINGS = {
      format:             "set it on the path with #format instead",
      file_name:          "where it only chooses the format when the path has none, set the format on the path with " \
                          "#format instead",
      original_file_name: "where it only chooses the format when the path has none, set the format on the path with " \
                          "#format instead",
      default_format:     "set the format on the path with #format instead, when the path has none, such as " \
                          "path.format(:json) unless path.format",
      format_options:     "set a schema on the path with #schema instead, which gives the width of each field of a " \
                          "fixed width file, such as the schema that IOStreams::Schema.from_layout returns for the " \
                          "layout, converted once and saved, since v3.0 removes from_layout"
    }.freeze
    private_constant :PATH_SETTINGS

    FORMAT_OPTIONS_DEPRECATION = "#format_options is deprecated, use #schema instead, which gives the width of each " \
                                 "field of a fixed width file".freeze
    private_constant :FORMAT_OPTIONS_DEPRECATION

    # The modes that a copy converts the data with, see #copy_from. Without a mode it copies the bytes.
    COPY_MODES = %i[line array hash].freeze
    private_constant :COPY_MODES

    # The number of bytes that a copy without a mode reads at a time, where it does not copy with `IO.copy_stream`, see
    # #copy_data, as many as CRuby's `IO.copy_stream` reads.
    COPY_SIZE = 16_384
    private_constant :COPY_SIZE

    # Whether `IO.copy_stream` writes the text that a source that is not an IO reads in the encoding that the source
    # gives it, as CRuby's does, so that a target that converts text, such as with #encoding, converts it, rather than
    # writing it as binary, as JRuby's does, see https://github.com/jruby/jruby/issues/9881, which such a target takes as
    # text already in its own encoding. Found by what it does, so that #copy_from uses it again once JRuby keeps the
    # encoding.
    COPY_STREAM_KEEPS_ENCODING =
      begin
        text   = "\u00E9"
        source = Object.new
        source.define_singleton_method(:read) do |_length = nil, buffer = nil|
          data = text
          text = nil
          buffer && data ? buffer.replace(data) : data
        end
        encoding = nil
        target   = Object.new
        target.define_singleton_method(:write) do |data|
          encoding = data.encoding
          data.bytesize
        end
        IO.copy_stream(source, target)
        encoding == Encoding::UTF_8
      end

    IO_STREAM_DEPRECATION = "#io_stream is deprecated, since v3.0 makes it private, keep the IO supplied to " \
                            "IOStreams.stream instead".freeze
    private_constant :IO_STREAM_DEPRECATION

    # The deprecation warning of a method of the stream that a reader block receives, which the stream that v3.0
    # supplies in its place does not answer, after the name of the method, with the name of the stream, see
    # #v3_deprecation.
    V3_READER_DEPRECATION = "is deprecated on %s that #reader yields, since in v3.0 it is a stream that only reads, " \
                            "with #read, #readpartial, #gets, #readline, #readlines, #each_line, #each and #eof?: read " \
                            "it with those, open the reader again to read it from the start, or copy the data into a " \
                            "local file first, such as with IOStreams.temp_file and #copy_to, where it must be a " \
                            "File".freeze
    private_constant :V3_READER_DEPRECATION

    # The deprecation warning of a method of the stream that a writer block receives, see V3_READER_DEPRECATION.
    V3_WRITER_DEPRECATION = "is deprecated on %s that #writer yields, since in v3.0 it is a stream that only writes, " \
                            "with #write, #<<, #print, #puts and #printf: write it with those".freeze
    private_constant :V3_WRITER_DEPRECATION

    def initialize(io_stream)
      raise(ArgumentError, "io_stream cannot be nil") if io_stream.nil?
      raise(ArgumentError, "io_stream must not be a string: #{io_stream.inspect}") if io_stream.is_a?(String)

      @io_stream = io_stream
      @builder   = nil
    end

    # A copy has its own streams, options and encoding, so that changing them does not change the original, see
    # `IOStreams::Builder#initialize_copy`.
    def initialize_copy(source)
      super
      @builder = @builder&.dup
    end

    # Deprecated: returns the IO, or other object, supplied to `IOStreams.stream`, which the caller already holds, or nil
    # for a path. v3.0 makes it private. Reports a deprecation warning, see `IOStreams::Deprecation`.
    def io_stream
      Deprecation.warn(IO_STREAM_DEPRECATION)
      supplied_io
    end

    # Ignore the filename and use only the supplied streams.
    #
    # See #option to set an option for one of the streams included based on the file name extensions.
    #
    # Example:
    #
    # IOStreams.path("tempfile2527").stream(:zip).stream(:pgp, passphrase: "receiver_passphrase").read
    def stream(stream, **)
      warn_change("#stream")
      builder.stream(stream, **)
      self
    end

    # Set the options for an element within the stream for this file.
    # If the relevant stream is not found for this file it is ignored.
    # For example, if the file does not have a pgp extension then the pgp option is not relevant.
    #
    # IOStreams.path("keep_safe.pgp").option(:pgp, passphrase: "receiver_passphrase").read
    #
    # # In this case the file is not pgp so the `passphrase` option is ignored.
    # IOStreams.path("keep_safe.enc").option(:pgp, passphrase: "receiver_passphrase").read
    #
    # IOStreams.path(output_file_name).option(:pgp, passphrase: "receiver_passphrase").read
    def option(stream, **)
      warn_change("#option")
      builder.option(stream, **)
      self
    end

    # Adds the options for the specified stream as an option,
    # but if streams have already been added it is instead added as a stream.
    def option_or_stream(stream, **)
      warn_change("#option_or_stream")
      builder.option_or_stream(stream, **)
      self
    end

    # Read and write the data as it is stored: no streams are applied, neither those that the file name implies
    # nor any set with #stream or #option, and no encoding set with #encoding.
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
    # Replaces `stream(:none)`, which is deprecated: it still works, and reports a deprecation warning, see
    # `IOStreams::Deprecation`.
    def raw
      warn_change("#raw")
      builder.raw
      self
    end

    # Returns [true|false] whether the data is read and written as it is stored, see #raw.
    def raw?
      builder.raw?
    end

    # Set the character encoding of the text that the application reads or writes, which the encode stream
    # converts, and its other options, `replace:` and `cleaner:`, see `IOStreams::Encode::Reader`. Unlike the streams
    # in the file name, the encoding stays with the path, whichever streams it has, and works for a stream without a
    # file name too. Each call merges its options with those already set.
    #
    # Raises ArgumentError when it is set, rather than when the data is read or written, for an option that the
    # encode stream does not take, or a value that it does not accept, such as an encoding that Ruby does not know, see
    # `IOStreams::Encode.check`.
    #
    # Examples:
    #
    # # Read binary lines from a compressed file, which is still decompressed.
    # IOStreams.path("data.csv.gz").encoding("BINARY").each(:line) { |line| p line }
    #
    # # Read UTF-8 text, removing the characters that are not printable.
    # IOStreams.path("export.csv").encoding("UTF-8", cleaner: :printable).each(:hash) { |hash| p hash }
    #
    # Replaces `option(:encode, ...)`, with the same options and the same results. Also replaces
    # `stream(:encode, ...)`, which, like any other stream set with #stream, stops the streams being taken from the
    # file name, which #encoding keeps: so to read or write the data as it is stored, as
    # `stream(:encode, encoding: "BINARY")` does for a file name such as `data.csv.gz`, use #raw instead, and to read a
    # file that is not named for its format, #file_name, then #encoding. Both are deprecated: they still work, and
    # report a deprecation warning, see `IOStreams::Deprecation`.
    #
    # Without any arguments, returns [String|Encoding|nil] the encoding that was set, or nil when none was, like
    # `IO#encoding`.
    def encoding(encoding = nil, **options)
      return builder.setting(:encode)&.[](:encoding) if encoding.nil? && options.empty?

      warn_change("#encoding")
      builder.encoding(encoding, **options)
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
      warn_change("#remove_from_pipeline")
      builder.remove_from_pipeline(stream_name)
      self
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
    #      or detected from a `.csv` file name.
    #   2. Or, in the `:line` mode, the `embedded_within` argument is supplied (e.g. `embedded_within: '"'`).
    # - Pass `embedded_within: nil` to read the physical lines of a quoted format in the `:line` mode.
    #   Supplying `embedded_within` in the `:array` and `:hash` modes is deprecated, since the format splits their
    #   lines: set the format with #format instead. It still applies, and reports a deprecation warning, see
    #   `IOStreams::Deprecation`.
    def each(mode = :line, **args, &block)
      raise(ArgumentError, "Invalid mode: #{mode.inspect}") if mode == :stream

      # Deliberately not returning an Enumerator when no block is given.
      # The stream pipeline manages resources via block scope: every stream is opened with an
      # `ensure` that closes the file handle, reaps the gpg subprocess, deletes temp files, etc.
      # A Fiber-backed Enumerator (e.g. `to_enum(__method__, mode, **args)`) would leave that block
      # suspended; if the caller abandons a partially-consumed enumerator, none of the cleanup runs
      # until GC collects the Fiber, leaking file descriptors, gpg processes, and temp files.
      reader(mode, **args) { |stream| stream.each(&block) }
    end

    # Returns a Reader for reading a file / stream
    #
    # Supplying options to the `:stream` mode, which ignores them, is deprecated, and reports a deprecation warning,
    # see `IOStreams::Deprecation`. So is supplying the settings of the file, such as `format:`, to the `:array` and
    # `:hash` modes, which are set on the path instead, such as with #format.
    #
    # The stream that the block of the `:stream` mode receives reports a deprecation warning for each of its methods that
    # the application calls, and that the stream that v3.0 supplies in its place does not answer, such as `#rewind` of the
    # `Zlib::GzipReader` of a `.gz` file, see #v3_deprecation.
    def reader(mode = :stream, **args, &)
      case mode
      when :stream
        warn_ignored_options(args.keys, "in the :stream mode")
        deprecation = v3_deprecation(:reader) if block_given?
        return stream_reader(&) unless deprecation

        stream_reader { |io| yield(Deprecation::Methods.deprecate(io, *deprecation)) }
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
    # Notes:
    # - Use with caution since large files can cause a denial of service since
    #   this method will load the entire file into memory.
    # - Recommend using instead `#reader` to read a block into memory at a time.
    def read(*args)
      reader { |stream| stream.read(*args) }
    end

    # Returns a Writer for writing to a file / stream
    #
    # Supplying options to the `:stream` mode, which ignores them, is deprecated, as are the settings of the file,
    # such as `format:`, for the `:array` and `:hash` modes, see #reader, and the options that only apply when
    # reading, such as `allowed_columns:`, which a writer ignores. So are the options supplied when the stream is a
    # line, row or record writer that is already open, such as the one that `writer(:line)` yields, handed to
    # `IOStreams.stream`, which writes with its own settings, and ignores them, and the streams, encoding, format and
    # schema set on such a stream, see #supplied_writer. Each reports a deprecation warning, see
    # `IOStreams::Deprecation`.
    def writer(mode = :stream, **args, &)
      case mode
      when :stream
        warn_ignored_options(args.keys, "in the :stream mode")
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
    #     Any other mode raises ArgumentError, before the source or the target is opened.
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
    # Notes:
    # - When the source or the target has a schema, see #schema, a copy of rows or records hands the target the header
    #   row of the source as the header row of the rows after it, which a target with a schema matches to its fields,
    #   and skips the blank rows, see `IOStreams::Row::Reader#copy_to`. Otherwise each row or record read is written,
    #   as before.
    # - The source is opened before the target, so that the target is not changed when the source cannot be read, for
    #   example when it does not exist. When the copy fails part way, the target discards its incomplete write, as a
    #   path does whenever a write fails.
    #
    # Supplying options to a copy without a `mode:`, which ignores them, is deprecated, as is supplying `mode:` or
    # other options to a copy with `convert: false`. Each reports a deprecation warning, see `IOStreams::Deprecation`.
    def copy_from(source, convert: true, mode: nil, **args)
      if convert
        validate_copy_mode!(mode)
        stream = IOStreams.new(source)
        if mode
          stream.reader(mode) do |rows|
            writer(mode, **args) do |target|
              if mode == :line || (schema.nil? && stream.schema.nil?)
                rows.each { |row| target << row }
              else
                rows.copy_to(target)
              end
            end
          end
        else
          warn_ignored_options(args.keys, "when copying without a `mode:`")
          stream.reader do |src|
            writer { |target| copy_data(src, target) }
          end
        end
      else
        warn_unconverted_copy_options(mode, args)
        stream = source.is_a?(Stream) ? source.dup : IOStreams.new(source)
        stream.no_streams.reader do |src|
          dup.no_streams.writer { |target| IO.copy_stream(src, target) }
        end
      end
    end

    def copy_to(target, **args)
      target = IOStreams.new(target)
      target.copy_from(self, **args)
    end

    # Set/get the original file_name
    def file_name(file_name = :none)
      if file_name == :none
        builder.file_name
      else
        warn_change("#file_name")
        builder.file_name = file_name
        self
      end
    end

    # Set the original file_name
    def file_name=(file_name)
      warn_change("#file_name=")
      builder.file_name = file_name
    end

    # Set/get the tabular format
    #
    # A format other than `:csv` set on a spreadsheet, such as `format(:psv)` on an `.xlsx` path, is deprecated, since
    # its rows are read as CSV, and reports a deprecation warning when its lines, rows or records are read, see
    # `IOStreams::Builder#warn_text_format`.
    def format(format = :none)
      if format == :none
        builder.format
      else
        warn_change("#format")
        builder.format = format
        self
      end
    end

    # Set the tabular format
    def format=(format)
      warn_change("#format=")
      builder.format = format
    end

    # Deprecated: use #schema, which gives the width of each field of a fixed width file, see docs/formats.md, and
    # `IOStreams::Schema.from_layout` for the schema of a layout. Reports a deprecation warning, see
    # `IOStreams::Deprecation`.
    #
    # Set/get the tabular format options: the layout of a fixed width file.
    def format_options(format_options = :none)
      Deprecation.warn(FORMAT_OPTIONS_DEPRECATION)
      if format_options == :none
        builder.format_options
      else
        builder.format_options = format_options
        self
      end
    end

    # Deprecated: use #schema=, see #format_options.
    #
    # Set the tabular format_options
    def format_options=(format_options)
      Deprecation.warn(FORMAT_OPTIONS_DEPRECATION)
      builder.format_options = format_options
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
    # Returns [Hash|String|IOStreams::Path] the schema as it was set, a Hash or String as a frozen copy, so that
    # changing the object that was supplied afterwards does not change it, or [nil] when none was set.
    #
    # Notes:
    # - Without a schema, rows and records are read and written as before.
    # - A schema cannot be supplied to each call of #each, #reader or #writer, nor with the layout of a fixed width
    #   file in #format_options, which raise ArgumentError.
    # - With a schema, the text of the file is read as UTF-8, unless an encoding is set with
    #   #encoding, and text that is not valid UTF-8 raises `IOStreams::Errors::InvalidEncoding`.
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
      # Compared by identity, since a path compares itself to another path, see `IOStreams::Path#==`.
      return builder.schema if schema.equal?(:none)

      warn_change("#schema")
      builder.schema = schema
      self
    end

    # Set the schema, see #schema.
    #
    # Raises ArgumentError when the schema is not a Hash, a String or a path, or is a Hash that is not a valid schema.
    def schema=(schema)
      warn_change("#schema=")
      builder.schema = schema
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

      Utils::PathName.basename(file_name, suffix)
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
      Utils::PathName.dirname(file_name) if file_name
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
      Utils::PathName.extname(file_name) if file_name
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
      extname&.sub(/^\./, "")
    end

    # Deprecated: it takes an internal object. To start again without the streams and options set with #stream or
    # #option, create the path again with `IOStreams.path`. Reports a deprecation warning, see
    # `IOStreams::Deprecation`.
    def builder=(builder)
      Deprecation.warn("#builder= is deprecated, since it takes an internal object, create the path again with " \
                       "IOStreams.path to start without the streams and options set with #stream or #option")
      @builder = builder
    end

    protected

    # Applies no streams, as `stream(:none)` does, for IOStreams itself, which never uses its own deprecated methods.
    def no_streams
      builder.no_streams
      self
    end

    # Starts again without the streams and options set with #stream or #option, for IOStreams itself, see #builder=.
    def reset_builder
      @builder = nil
      self
    end

    # Options supplied to a copy with `convert: false`, which ignores them, are deprecated, including `mode:`.
    def warn_unconverted_copy_options(mode, args)
      names = args.keys
      names.unshift(:mode) unless mode.nil?
      warn_ignored_options(names, "for a copy with convert: false")
    end

    private

    # Copies the data that the supplied source reads to the supplied target, as `IO.copy_stream` does, keeping the
    # encoding of the text that the source reads, so that a target that converts text converts it, see
    # COPY_STREAM_KEEPS_ENCODING. It reads without a buffer, as JRuby's `IO.copy_stream` does, since not every source
    # takes one, such as JRuby's `Zlib::GzipReader`, see https://github.com/jruby/jruby/issues/9884.
    #
    # Returns [Integer] the number of bytes copied, which the target says that it wrote, as for `IO.copy_stream`.
    def copy_data(source, target)
      return IO.copy_stream(source, target) if COPY_STREAM_KEEPS_ENCODING

      copied = 0
      while (data = source.read(COPY_SIZE))
        copied += target.write(data)
      end
      copied
    end

    def builder
      @builder ||= IOStreams::Builder.new
    end

    # Returns the IO, or other object, supplied to `IOStreams.stream`, or nil for a path, for IOStreams itself, see
    # #io_stream.
    def supplied_io
      @io_stream
    end

    # Called with the name of each method that changes this stream in place, such as "#stream", before it changes it,
    # so that a subclass can report a deprecation warning when changing it is deprecated, see
    # `IOStreams::Path#warn_change`. A stream reports none.
    def warn_change(_method_name)
      nil
    end

    # Returns [Array(Array<Symbol>, String)|nil] the methods that the stream that the block of the :stream mode of the
    # supplied type receives answers in v3.0, and the deprecation warning of each of its other methods that the
    # application calls, after the name of the method, when the stream that it receives in v2.2 answers others, see
    # `IOStreams::Builder#v3_stream`, otherwise nil, so that #reader and #writer extend the stream with them, see
    # `IOStreams::Deprecation::Methods`, and otherwise hand the block on unchanged. Known before the streams are
    # opened, since the streams that v3.0 replaces are those of IOStreams itself, each of which yields one stream.
    def v3_deprecation(type)
      reading       = type == :reader
      methods, name = builder.v3_stream(type, reading ? v3_source : nil, reading && v3_reads_file?)
      [methods, (reading ? V3_READER_DEPRECATION : V3_WRITER_DEPRECATION) % name] if methods
    end

    # Returns [Array(Array<Symbol>, String)|nil] the methods that the IO that the streams of this stream read in v3.0
    # answers, and its name for a deprecation warning, when it is not the IO that they read in v2.2, see
    # `IOStreams::Builder#v3_stream`, otherwise nil, as for the IO supplied to `IOStreams.stream`, which v3.0 reads too.
    def v3_source
      nil
    end

    # Returns [true|false] whether the streams of this stream read a regular local file in v3.0: the IO supplied to
    # `IOStreams.stream`, when it is an open File, or the File of a Tempfile, which gpg reads itself in v3.0, see
    # `IOStreams::Pgp::Reader.v3_stream_methods`.
    def v3_reads_file?
      io = supplied_io
      io = io.__getobj__ if defined?(::Delegator) && io.is_a?(::Delegator)
      io.is_a?(::File) && !io.closed? && io.stat.file?
    rescue IOError, SystemCallError
      false
    end

    # Raises ArgumentError for a mode that a copy does not convert with, see COPY_MODES, before the source or the target
    # is opened.
    def validate_copy_mode!(mode)
      return if mode.nil? || COPY_MODES.include?(mode)

      raise(ArgumentError, "Invalid mode: #{mode.inspect}. A copy converts lines, rows or records with mode: " \
                           "#{COPY_MODES.map(&:inspect).join(', ')}, or copies the data, as bytes, without a mode")
    end

    def stream_reader(&)
      builder.reader(supplied_io, &)
    end

    # Yields the reader of the lines of this stream, which the readers of its rows and records read too.
    #
    # A format set with #format that is not that of the text of its streams, such as `:psv` for a spreadsheet, whose
    # rows are read as CSV, reports a deprecation warning, see `IOStreams::Builder#warn_text_format`.
    def line_reader(embedded_within: :auto, **args)
      builder.warn_text_format
      # `:auto` defers the decision to the resolved tabular format (e.g. CSV quotes with `"`),
      # while distinguishing "not supplied" from an explicit value such as `nil` (disable) or
      # `'"'` (force). Centralizing this in the builder keeps all format-based decisions there.
      embedded_within = builder.quote_character if embedded_within == :auto
      reader_class    = builder.utf8_text? ? IOStreams::Line::Utf8Reader : IOStreams::Line::Reader

      stream_reader do |io|
        yield reader_class.new(
          io,
          embedded_within: embedded_within,
          **args
        )
      end
    end

    # Iterate over a file / stream returning each line as an array, one at a time.
    #
    # Supplying `embedded_within:` is deprecated, since the format of the file decides where its lines are split, and
    # reports a deprecation warning, see `IOStreams::Deprecation`.
    def row_reader(delimiter: nil, embedded_within: :auto, **args, &)
      rows_reader(IOStreams::Row::Reader, delimiter, embedded_within, args, &)
    end

    # Iterate over a file / stream returning each line as a hash, one at a time.
    #
    # Supplying `embedded_within:` is deprecated, see #row_reader.
    def record_reader(delimiter: nil, embedded_within: :auto, **args, &)
      rows_reader(IOStreams::Record::Reader, delimiter, embedded_within, args, &)
    end

    # Yields the reader of the rows or records of this stream, an instance of the supplied class, with the options of
    # the call.
    #
    # With a schema, an option that the call cannot supply raises before a deprecation warning is reported for any of
    # its other options, so that a call that fails reports only its failure, see #schema_tabular. Then each deprecated
    # option of the call reports a deprecation warning, see #warn_read_options.
    def rows_reader(klass, delimiter, embedded_within, args)
      tabular = schema_tabular(args)
      warn_read_options(embedded_within, args)
      line_reader(delimiter: delimiter, embedded_within: embedded_within) do |io|
        yield klass.new(io, **tabular_options(tabular, args))
      end
    end

    # Reports a deprecation warning for the deprecated options of a call that reads rows or records: the settings of the
    # file, see #warn_path_settings, `embedded_within:`, and the column options, which
    # `IOStreams::Tabular.deprecated_read_option_names` names.
    def warn_read_options(embedded_within, args)
      warn_path_settings(args)
      warn_embedded_within(embedded_within)
      warn_column_options(IOStreams::Tabular.deprecated_read_option_names(args))
    end

    # Reports a deprecation warning for the deprecated options of a call that writes rows or records: the settings of
    # the file, see #warn_path_settings, the options that only apply when reading, see #warn_read_only_options, and the
    # column options, which `IOStreams::Tabular.deprecated_write_option_names` names.
    def warn_write_options(args)
      warn_path_settings(args)
      warn_read_only_options(args)
      warn_column_options(IOStreams::Tabular.deprecated_write_option_names(args))
    end

    # The settings of the file supplied to a call, see #path_setting_names, are deprecated, even when they are nil,
    # since v3.0 raises ArgumentError for each of them. Each one reports how to set it on the path instead, see
    # PATH_SETTINGS, apart from `format_options:` with a schema, which raises for a layout, see #schema_tabular, so that
    # the one that it accepts, nil or empty, has no effect, and is reported with the advice to remove it.
    #
    # When the streams read the rows in a format of their own, such as those of a spreadsheet as CSV, see
    # `IOStreams::Builder#text_format`, the settings that choose the format, see #format_setting_names, report that
    # format as the one to set on the path, since any other is deprecated there too, see
    # `IOStreams::Builder#warn_text_format`. It is only looked for while deprecation warnings are on, see
    # `IOStreams::Deprecation.on?`, since it builds the pipeline.
    def warn_path_settings(args)
      names        = args.keys & path_setting_names
      format_names = format_setting_names
      text_format  = builder.text_format if Deprecation.on? && names.intersect?(format_names)
      names.each do |name|
        advice =
          if name == :format_options && !builder.schema.nil?
            "and has no effect with a schema, so remove it"
          elsif text_format && format_names.include?(name)
            "set format(#{text_format.inspect}) on the path instead, since the streams read the rows as " \
              "#{text_format.inspect}, such as those of a spreadsheet"
          else
            PATH_SETTINGS.fetch(name)
          end
        Deprecation.warn("#{name}: is deprecated for each call, #{advice}")
      end
    end

    # Returns [Array<Symbol>] the names of the options of a call that describe the file: those of the tabular, see
    # `IOStreams::Tabular::FORMAT_OPTION_NAMES`, other than `schema:`, which raises, see #reject_schema_option!, and
    # `original_file_name:`, with which the readers and writers of rows and records take the file name of the path, see
    # #tabular_options, which the option of the call replaces.
    def path_setting_names
      [*(IOStreams::Tabular::FORMAT_OPTION_NAMES - %i[schema]), :original_file_name]
    end

    # Returns [Array<Symbol>] the names of the options of a call that choose the format of the file, in place of the
    # format of its path: those that describe the file, see #path_setting_names, other than `format_options:`, which
    # describes the fields of a fixed width file.
    def format_setting_names
      path_setting_names - %i[format_options]
    end

    # The options that only apply when reading a header, see `IOStreams::Tabular::Header::READ_OPTION_NAMES`, are
    # deprecated when writing, which ignores them, even when they are nil, since v3.0 raises ArgumentError for them.
    def warn_read_only_options(args)
      names = args.keys & IOStreams::Tabular::Header::READ_OPTION_NAMES
      return if names.empty?

      words  = Deprecation::Words.new(names)
      advice =
        if builder.schema.nil?
          "describe the columns that are written with #schema instead"
        else
          "so remove #{words.them}"
        end
      Deprecation.warn("#{words.keywords} #{words.are} deprecated when writing, since " \
                       "#{words.one? ? 'it only applies' : 'they only apply'} when reading and #{words.are} ignored, " \
                       "#{advice}")
    end

    # The column options of each call are deprecated, since a schema describes the columns of the file on its path, see
    # #schema. With a schema, which raises for those that describe the columns, see #schema_tabular, the others that it
    # accepts have no effect, so they are reported with the advice to remove them.
    def warn_column_options(names)
      return if names.empty?

      words  = Deprecation::Words.new(names)
      advice =
        if builder.schema.nil?
          "describe the columns of the file with #schema instead"
        else
          "and #{words.one? ? 'has' : 'have'} no effect with a schema, which describes the columns of the file, so " \
            "remove #{words.them}"
        end
      Deprecation.warn("#{words.keywords} #{words.are} deprecated, #{advice}")
    end

    # Options that are ignored, such as those supplied to the `:stream` mode, are deprecated.
    def warn_ignored_options(names, where)
      return if names.empty?

      words = Deprecation::Words.new(names)
      Deprecation.warn("#{words.keywords} #{words.are} deprecated #{where}, which ignores #{words.them}, so remove " \
                       "#{words.them}")
    end

    def warn_embedded_within(embedded_within)
      return if embedded_within == :auto

      Deprecation.warn("embedded_within: is deprecated when reading rows and records, since the format of the file " \
                       "decides where their lines are split, set it with #format instead, such as format(:psv) " \
                       "for values that are not quoted")
    end

    # Returns [IOStreams::Tabular|nil] the tabular that reads or writes the rows or records of this stream with the
    # options of the call, when it has a schema, see #schema, which is created before the file is opened, so that its
    # schema file is read, and an option that the schema does not accept raises, before the file is opened, or a writer
    # replaces it. Returns nil without a schema, see #tabular_options.
    #
    # Like the readers and writers of rows and records without a schema, see #tabular_options, it takes the format from
    # the file name of the path, or from the `original_file_name:` of the call, which replaces it, or from the
    # `file_name:` of the call, which replaces both.
    #
    # Its text is taken as UTF-8, see `IOStreams::Builder#utf8_text?`, unless the application chose its encoding, or read
    # it as it is stored, when it is `decoded:`, so that the text read is taken as it is, and binary text written that
    # is not valid UTF-8 is left for the encoding. The lines that it reads are UTF-8 already, see #line_reader, so it
    # only checks them.
    #
    # Raises ArgumentError for `schema:`, which is set on the path.
    def schema_tabular(args)
      schema = builder.tabular_schema
      return unless schema

      reject_schema_option!(args)
      IOStreams::Tabular.new(
        file_name:      args.fetch(:original_file_name, builder.file_name),
        format:         builder.format,
        format_options: builder.format_options,
        schema:         schema,
        decoded:        !builder.utf8_text?,
        **args.except(:original_file_name)
      )
    end

    # Returns [Hash] the options of the reader or writer of the rows or records of this stream: the tabular that reads or
    # writes them with a schema, see #schema_tabular, otherwise the tabular format of this stream and the options of
    # the call, from which it creates its own, as before.
    #
    # Raises ArgumentError for `schema:`, which is set on the path.
    def tabular_options(tabular, args)
      return {tabular: tabular} if tabular

      reject_schema_option!(args)
      {original_file_name: builder.file_name, format: builder.format, format_options: builder.format_options, **args}
    end

    # Raises ArgumentError for `schema:` supplied to a call, since the schema describes the file, so it is set on the
    # path, see #schema, as is the format.
    def reject_schema_option!(args)
      return unless args.key?(:schema)

      raise(ArgumentError, ":schema cannot be supplied to each call, set it on the path instead, for example: " \
                           "path.schema(\"people.json\").each(:hash)")
    end

    def stream_writer(&)
      builder.writer(supplied_io, &)
    end

    def line_writer(**args, &block)
      return supplied_writer(IOStreams::Line::Writer, args, &block) if supplied_io.is_a?(IOStreams::Line::Writer)

      writer do |io|
        IOStreams::Line::Writer.stream(io, **args, &block)
      end
    end

    def row_writer(**args, &)
      rows_writer(IOStreams::Row::Writer, args, &)
    end

    def record_writer(**args, &)
      rows_writer(IOStreams::Record::Writer, args, &)
    end

    # Yields the writer of the rows or records of this stream, an instance of the supplied class, with the options of
    # the call, which writes its lines with the `delimiter:` of the call, or that of the line writer by default, see
    # `IOStreams::Line::Writer`.
    #
    # As with a reader, see #rows_reader, with a schema an option that the call cannot supply raises before a deprecation
    # warning is reported for any of its other options, see #warn_write_options.
    def rows_writer(klass, args, &block)
      return supplied_writer(klass, args, &block) if supplied_io.is_a?(klass)

      options = args.except(:delimiter)
      tabular = schema_tabular(options)
      warn_write_options(options)
      rows_line_writer(args.slice(:delimiter)) do |io|
        klass.stream(io, **tabular_options(tabular, options), &block)
      end
    end

    # Yields the line writer that the rows or records of this stream are written to, in its format and by its schema,
    # with the supplied options: a line writer supplied to `IOStreams.stream`, which writes them in its own lines, see
    # #supplied_writer, otherwise one of this stream, see #line_writer.
    def rows_line_writer(args, &)
      return supplied_writer(IOStreams::Line::Writer, args, rows: true, &) if supplied_io.is_a?(IOStreams::Line::Writer)

      line_writer(**args, &)
    end

    # Yields this stream's IO, which is a writer of the supplied class that is already open, such as the one that
    # `writer(:line)` yields, handed to code that writes with `IOStreams.stream(io).writer(:line)`, which then writes into
    # it. It writes with its own settings, so it ignores the options of the call, the streams, options and encoding of
    # this stream, and its format and schema, other than those of the rows or records that are written to a line writer
    # (rows: true), which apply, see #rows_line_writer. Each is deprecated, since v3.0 raises ArgumentError for it, see
    # #warn_supplied_writer_options and #warn_supplied_writer_settings.
    def supplied_writer(klass, args, rows: false)
      warn_supplied_writer_options(klass, args)
      warn_supplied_writer_settings(klass, rows)
      yield(supplied_io)
    end

    # Reports a deprecation warning for the options of a call that the supplied writer ignores, see #supplied_writer:
    # each of them, even when it is nil, other than a nil `delimiter:`, the only option of a writer of v3.0, which
    # accepts it, and raises ArgumentError for any other.
    def warn_supplied_writer_options(klass, args)
      names = args.reject { |name, value| name == :delimiter && value.nil? }.keys
      return if names.empty?

      words = Deprecation::Words.new(names)
      warn_supplied_writer(klass, words.keywords, words)
    end

    # Reports a deprecation warning for the settings of this stream that the supplied writer ignores, see
    # #supplied_writer, as the builder answers them, see `IOStreams::Builder#writer_settings`: the streams of its
    # pipeline, and, unless the rows or records of this stream are written to it, which apply them, its format and
    # schema.
    def warn_supplied_writer_settings(klass, rows)
      settings = builder.writer_settings
      streams  = settings[:streams]
      unless streams.empty?
        words = Deprecation::Words.new(streams)
        warn_supplied_writer(klass, "the #{words.one? ? 'stream' : 'streams'} #{streams.map(&:inspect).join(', ')} " \
                                    "that #stream, #option, #encoding or #file_name set", words)
      end
      return if rows || settings[:tabular].empty?

      names = settings[:tabular].map { |name| "##{name}" }
      warn_supplied_writer(klass, names.join(" and "), Deprecation::Words.new(names))
    end

    # Reports that what the subject names, which the words are about, see `IOStreams::Deprecation::Words`, is deprecated
    # for the supplied writer, which is already open, and ignores it.
    def warn_supplied_writer(klass, subject, words)
      Deprecation.warn("#{subject} #{words.are} deprecated for the #{klass.name} supplied to IOStreams.stream, which " \
                       "is already open and writes with its own settings, so #{words.they_are} ignored: set " \
                       "#{words.them} where that writer is opened instead, or remove #{words.them}")
    end
  end
end
