module IOStreams
  class Stream
    attr_reader :io_stream
    attr_writer :builder

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
    # IOStreams.path('tempfile2527').stream(:zip).stream(:pgp, passphrase: 'receiver_passphrase').reader(&:read)
    def stream(stream, **options)
      builder.stream(stream, **options)
      self
    end

    # Set the options for an element within the stream for this file.
    # If the relevant stream is not found for this file it is ignored.
    # For example, if the file does not have a pgp extension then the pgp option is not relevant.
    #
    # IOStreams.path('keep_safe.pgp').option(:pgp, passphrase: 'receiver_passphrase').reader(&:read)
    #
    # # In this case the file is not pgp so the `passphrase` option is ignored.
    # IOStreams.path('keep_safe.enc').option(:pgp, passphrase: 'receiver_passphrase').reader(&:read)
    #
    # IOStreams.path(output_file_name).option(:pgp, passphrase: 'receiver_passphrase').reader(&:read)
    def option(stream, **options)
      builder.option(stream, **options)
      self
    end

    # Adds the options for the specified stream as an option,
    # but if streams have already been added it is instead added as a stream.
    def option_or_stream(stream, **options)
      builder.option_or_stream(stream, **options)
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
    # - Embedded lines (within double quotes) will be skipped if
    #   1. The file name contains .csv
    #   2. Or the embedded_within argument is set
    def each(mode = :line, **args, &block)
      raise(ArgumentError, "Invalid mode: #{mode.inspect}") if mode == :stream

      #    return enum_for __method__ unless block_given?
      reader(mode, **args) { |stream| stream.each(&block) }
    end

    # Returns a Reader for reading a file / stream
    def reader(mode = :stream, **args, &block)
      case mode
      when :stream
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
    # Notes:
    # - Use with caution since large files can cause a denial of service since
    #   this method will load the entire file into memory.
    # - Recommend using instead `#reader` to read a block into memory at a time.
    def read(*args)
      reader { |stream| stream.read(*args) }
    end

    # Returns a Writer for writing to a file / stream
    def writer(mode = :stream, **args, &block)
      case mode
      when :stream
        stream_writer(&block)
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
    # Examples:
    #
    # # Copy and convert streams based on file extensions
    # IOStreams.path("target_file.json").copy_from("source_file_name.csv.gz")
    #
    # # Copy "as-is" without any automated stream conversions
    # IOStreams.path("target_file.json").copy_from("source_file_name.csv.gz", convert: false)
    #
    # # Advanced copy with custom stream conversions on source and target.
    # source = IOStreams.path("source_file").stream(encoding: "BINARY")
    # IOStreams.path("target_file.pgp").option(:pgp, passphrase: "hello").copy_from(source)
    def copy_from(source, convert: true)
      if convert
        stream = IOStreams.new(source)
        writer do |target|
          stream.reader { |src| IO.copy_stream(src, target) }
        end
      else
        stream = source.is_a?(Stream) ? source.dup : IOStreams.new(source)
        dup.stream(:none).writer do |target|
          stream.stream(:none).reader { |src| IO.copy_stream(src, target) }
        end
      end
    end

    def copy_to(target, convert: true)
      target = IOStreams.path(target) unless target.is_a?(Stream)
      target.copy_from(self, convert: convert)
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

    # Set/get the original file_name
    def file_name=(file_name)
      builder.file_name = file_name
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

    private

    def builder
      @builder ||= IOStreams::Builder.new
    end

    def stream_reader(&block)
      builder.reader(io_stream, &block)
    end

    def line_reader(embedded_within: nil, **args)
      embedded_within = '"' if embedded_within.nil? && builder.file_name&.include?(".csv")

      stream_reader { |io| yield IOStreams::Line::Reader.new(io, original_file_name: builder.file_name, embedded_within: embedded_within, **args) }
    end

    # Iterate over a file / stream returning each line as an array, one at a time.
    def row_reader(delimiter: nil, embedded_within: nil, **args)
      line_reader(delimiter: delimiter, embedded_within: embedded_within) do |io|
        yield IOStreams::Row::Reader.new(io, original_file_name: builder.file_name, **args)
      end
    end

    # Iterate over a file / stream returning each line as a hash, one at a time.
    def record_reader(delimiter: nil, embedded_within: nil, **args)
      line_reader(delimiter: delimiter, embedded_within: embedded_within) do |io|
        yield IOStreams::Record::Reader.new(io, original_file_name: builder.file_name, **args)
      end
    end

    def stream_writer(&block)
      builder.writer(io_stream, &block)
    end

    def line_writer(**args, &block)
      return block.call(io_stream) if io_stream&.is_a?(IOStreams::Line::Writer)

      writer { |io| IOStreams::Line::Writer.stream(io, original_file_name: builder.file_name, **args, &block) }
    end

    def row_writer(delimiter: $/, **args, &block)
      return block.call(io_stream) if io_stream&.is_a?(IOStreams::Row::Writer)

      line_writer(delimiter: delimiter) { |io| IOStreams::Row::Writer.stream(io, original_file_name: builder.file_name, **args, &block) }
    end

    def record_writer(delimiter: $/, **args, &block)
      return block.call(io_stream) if io_stream&.is_a?(IOStreams::Record::Writer)

      line_writer(delimiter: delimiter) { |io| IOStreams::Record::Writer.stream(io, original_file_name: builder.file_name, **args, &block) }
    end
  end
end
