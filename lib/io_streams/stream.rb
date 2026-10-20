module IOStreams
  class Stream
    # The settings of the file that the readers and writers of rows and records accept for each call, which v3.0
    # only accepts on the path, and the method of the path that sets each one.
    PATH_SETTINGS = {
      format:             "#format",
      file_name:          "#file_name",
      original_file_name: "#file_name",
      default_format:     "#format",
      format_options:     "#schema"
    }.freeze
    private_constant :PATH_SETTINGS

    FORMAT_OPTIONS_DEPRECATION = "#format_options is deprecated, use #schema instead, which gives the width of each " \
                                 "field of a fixed width file".freeze
    private_constant :FORMAT_OPTIONS_DEPRECATION

    attr_reader :io_stream

    def initialize(io_stream)
      raise(ArgumentError, "io_stream cannot be nil") if io_stream.nil?
      raise(ArgumentError, "io_stream must not be a string: #{io_stream.inspect}") if io_stream.is_a?(String)

      @io_stream = io_stream
      @builder   = nil
    end

    # Ignore the filename and use only the supplied streams.
    #
    # See #option to set an option for one of the streams included based on the file name extensions.
    #
    # Example:
    #
    # IOStreams.path("tempfile2527").stream(:zip).stream(:pgp, passphrase: "receiver_passphrase").read
    def stream(stream, **)
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
      builder.option(stream, **)
      self
    end

    # Adds the options for the specified stream as an option,
    # but if streams have already been added it is instead added as a stream.
    def option_or_stream(stream, **)
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
    # Replaces `stream(:none)`, which still works.
    def raw
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
    # Examples:
    #
    # # Read binary lines from a compressed file, which is still decompressed.
    # IOStreams.path("data.csv.gz").encoding("BINARY").each(:line) { |line| p line }
    #
    # # Read UTF-8 text, removing the characters that are not printable.
    # IOStreams.path("export.csv").encoding("UTF-8", cleaner: :printable).each(:hash) { |hash| p hash }
    #
    # Replaces `option(:encode, ...)` and `stream(:encode, ...)`, which still work, with the same options and the
    # same results.
    #
    # Without any arguments, returns [String|Encoding|nil] the encoding that was set, or nil when none was, like
    # `IO#encoding`.
    def encoding(encoding = nil, **options)
      return builder.setting(:encode)&.[](:encoding) if encoding.nil? && options.empty?

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
    #   1. The resolved tabular format quotes its fields (e.g. CSV, whether detected from a
    #      `.csv` file name or set explicitly via `.format(:csv)`)
    #   2. Or the `embedded_within` argument is supplied (e.g. `embedded_within: '"'`)
    # - Pass `embedded_within: nil` to disable quote-aware line joining for a quoted format.
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
    def reader(mode = :stream, **args, &)
      case mode
      when :stream
        warn_ignored_options(args.keys, "in the :stream mode")
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
    # reading, such as `allowed_columns:`, which a writer ignores. Each reports a deprecation warning, see
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
    def copy_from(source, convert: true, mode: nil, **args)
      if convert
        stream = IOStreams.new(source)
        if mode
          writer(mode, **args) do |target|
            if mode == :line || (schema.nil? && stream.schema.nil?)
              stream.each(mode) { |row| target << row }
            else
              stream.reader(mode) { |rows| rows.copy_to(target) }
            end
          end
        else
          writer(**args) do |target|
            stream.reader { |src| IO.copy_stream(src, target) }
          end
        end
      else
        warn_unconverted_copy_options(mode, args)
        stream = source.is_a?(Stream) ? source.dup : IOStreams.new(source)
        dup.no_streams.writer do |target|
          stream.no_streams.reader { |src| IO.copy_stream(src, target) }
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
        builder.file_name = file_name
        self
      end
    end

    # Set the original file_name
    def file_name=(file_name)
      builder.file_name = file_name
    end

    # Set/get the tabular format_options
    def format(format = :none)
      if format == :none
        builder.format
      else
        builder.format = format
        self
      end
    end

    # Set the tabular format
    def format=(format)
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

      self.schema = schema
      self
    end

    # Set the schema, see #schema.
    #
    # Raises ArgumentError when the schema is not a Hash, a String or a path, or is a Hash that is not a valid schema.
    def schema=(schema)
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

    def builder
      @builder ||= IOStreams::Builder.new
    end

    def stream_reader(&)
      builder.reader(io_stream, &)
    end

    def line_reader(embedded_within: :auto, **args)
      # `:auto` defers the decision to the resolved tabular format (e.g. CSV quotes with `"`),
      # while distinguishing "not supplied" from an explicit value such as `nil` (disable) or
      # `'"'` (force). Centralizing this in the builder keeps all format-based decisions there.
      embedded_within = builder.quote_character if embedded_within == :auto
      reader_class    = utf8_lines? ? IOStreams::Line::Utf8Reader : IOStreams::Line::Reader

      stream_reader do |io|
        yield reader_class.new(
          io,
          embedded_within: embedded_within,
          **args
        )
      end
    end

    # Returns [true|false] whether the lines read are taken as UTF-8, see `IOStreams::Line::Utf8Reader`: those of a file
    # with a schema, whose text is UTF-8, see #schema, unless an encoding is set on the encode stream, which decodes it
    # instead, as the rows and records of the file are read, see #schema_tabular.
    def utf8_lines?
      !builder.schema.nil? && builder.setting(:encode).nil?
    end

    # Iterate over a file / stream returning each line as an array, one at a time.
    #
    # Supplying `embedded_within:` is deprecated, since the format of the file decides where its lines are split, and
    # reports a deprecation warning, see `IOStreams::Deprecation`.
    def row_reader(delimiter: nil, embedded_within: :auto, **args)
      warn_path_settings(args)
      warn_embedded_within(embedded_within)
      warn_column_options(read_column_options(args))
      tabular = schema_tabular(args)
      line_reader(delimiter: delimiter, embedded_within: embedded_within) do |io|
        yield IOStreams::Row::Reader.new(io, **tabular_options(tabular, args))
      end
    end

    # Iterate over a file / stream returning each line as a hash, one at a time.
    #
    # Supplying `embedded_within:` is deprecated, see #row_reader.
    def record_reader(delimiter: nil, embedded_within: :auto, **args)
      warn_path_settings(args)
      warn_embedded_within(embedded_within)
      warn_column_options(read_column_options(args))
      tabular = schema_tabular(args)
      line_reader(delimiter: delimiter, embedded_within: embedded_within) do |io|
        yield IOStreams::Record::Reader.new(io, **tabular_options(tabular, args))
      end
    end

    # The settings of the file supplied for each call, see PATH_SETTINGS, are deprecated.
    def warn_path_settings(args)
      (args.keys & PATH_SETTINGS.keys).each do |name|
        Deprecation.warn("#{name}: is deprecated for each call, set it on the path with #{PATH_SETTINGS[name]} instead")
      end
    end

    # The options that only apply when reading, which a writer ignores, are deprecated when writing.
    def warn_read_options(args)
      names = args.keys & IOStreams::Tabular::Header::READ_OPTION_NAMES
      return if names.empty?

      Deprecation.warn("#{keywords(names)} #{names.size == 1 ? 'is' : 'are'} deprecated when writing, since " \
                       "#{names.size == 1 ? 'it only applies' : 'they only apply'} when reading and " \
                       "#{names.size == 1 ? 'is' : 'are'} ignored, describe the columns that are written with #schema " \
                       "instead")
    end

    # Returns [Array<Symbol>] the column options supplied to a reader, which are deprecated: the options of the header
    # that are not nil, see `IOStreams::Tabular::Header::OPTION_NAMES`, and `cleanse_header:`, even when it is nil,
    # which does not cleanse the header row.
    def read_column_options(args)
      names = args.compact.keys & IOStreams::Tabular::Header::OPTION_NAMES
      names << :cleanse_header if args.key?(:cleanse_header)
      names
    end

    # Returns [Array<Symbol>] the column options supplied to a writer that are not nil, other than those that only apply
    # when reading, see #warn_read_options.
    def written_column_options(args)
      args.compact.keys & (IOStreams::Tabular::Header::OPTION_NAMES - IOStreams::Tabular::Header::READ_OPTION_NAMES)
    end

    # The column options of each call are deprecated, since a schema describes the columns of the file on its path,
    # see #schema. With a schema, those other than `skip_unknown:` raise instead, see `IOStreams::Tabular`, so only
    # `skip_unknown:` is reported with one, which a schema accepts.
    def warn_column_options(names)
      names &= %i[skip_unknown] unless builder.schema.nil?
      return if names.empty?

      Deprecation.warn("#{keywords(names)} #{names.size == 1 ? 'is' : 'are'} deprecated, describe the columns of the " \
                       "file with #schema instead")
    end

    # Options that are ignored, such as those supplied to the `:stream` mode, are deprecated.
    def warn_ignored_options(names, where)
      return if names.empty?

      Deprecation.warn("#{keywords(names)} #{names.size == 1 ? 'is' : 'are'} deprecated #{where}, which ignores " \
                       "#{names.size == 1 ? 'it' : 'them'}, so remove #{names.size == 1 ? 'it' : 'them'}")
    end

    def keywords(names)
      names.map { |name| "#{name}:" }.join(", ")
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
    # The text that it reads is UTF-8, unless an encoding is set on the encode stream, which decodes it instead.
    #
    # Raises ArgumentError for `schema:`, which is set on the path.
    def schema_tabular(args)
      schema = builder.tabular_schema
      return unless schema

      reject_schema_option!(args)
      IOStreams::Tabular.new(
        file_name:      builder.file_name,
        format:         builder.format,
        format_options: builder.format_options,
        schema:         schema,
        decoded:        !builder.setting(:encode).nil?,
        **args
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
      builder.writer(io_stream, &)
    end

    def line_writer(**args, &block)
      return block.call(io_stream) if io_stream.is_a?(IOStreams::Line::Writer)

      writer do |io|
        IOStreams::Line::Writer.stream(io, **args, &block)
      end
    end

    def row_writer(delimiter: $/, **args, &block)
      warn_path_settings(args)
      warn_read_options(args)
      warn_column_options(written_column_options(args))
      return block.call(io_stream) if io_stream.is_a?(IOStreams::Row::Writer)

      tabular = schema_tabular(args)
      line_writer(delimiter: delimiter) do |io|
        IOStreams::Row::Writer.stream(io, **tabular_options(tabular, args), &block)
      end
    end

    def record_writer(delimiter: $/, **args, &block)
      warn_path_settings(args)
      warn_read_options(args)
      warn_column_options(written_column_options(args))
      return block.call(io_stream) if io_stream.is_a?(IOStreams::Record::Writer)

      tabular = schema_tabular(args)
      line_writer(delimiter: delimiter) do |io|
        IOStreams::Record::Writer.stream(io, **tabular_options(tabular, args), &block)
      end
    end
  end
end
