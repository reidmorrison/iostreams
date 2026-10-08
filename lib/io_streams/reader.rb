module IOStreams
  class Reader
    # Returns [Array<Symbol>] the names of the options this reader accepts,
    # or [nil] when the reader does not declare them.
    #
    # When declared, only these options are passed to the reader.
    def self.option_names
      nil
    end

    # Returns [Array<Symbol>] the names of the options that are valid when reading the stream,
    # or [nil] to accept the options of both the reader and the writer of its format,
    # see `IOStreams::StreamFormat#valid_option_names`.
    #
    # `IOStreams::Builder` rejects any other option before the reader is opened, naming the direction
    # an option belongs to when it is only valid for the other direction.
    #
    # One option hash is shared by the reader and the writer for a stream, so that the same path can be
    # written and then read. So by default the writer's options are also valid when reading, and are
    # ignored, since only `option_names` are passed to the reader. Override this to exclude an option of
    # the writer that a caller could expect to have an effect when reading, which must raise until the
    # reader supports it.
    def self.valid_option_names
      nil
    end

    # Returns [Array<Symbol>] the names of the options whose values must not be displayed, such as a passphrase,
    # so that `#inspect` on a path or stream does not display them, see `IOStreams::StreamFormat#redact_options`.
    def self.sensitive_option_names
      []
    end

    # When a Reader does not support streams, it reads the file of the stream when the stream is already
    # a local file, see `.input_file_name`. Otherwise the stream is copied to a local temp file,
    # and that file name is passed to this reader.
    def self.stream(input_stream, **args, &block)
      local_file_name = input_file_name(input_stream)
      if local_file_name
        result = file(local_file_name, **args, &block)
        # Leave the stream at its end, as if it had been copied.
        input_stream.seek(0, ::IO::SEEK_END)
        return result
      end

      purpose = "a copy of the input of #{self}, which only reads files"
      Utils.private_temp_file("iostreams_reader", purpose: purpose) do |file_name|
        ::File.open(file_name, "wb") { |target| ::IO.copy_stream(input_stream, target) }
        file(file_name, **args, &block)
      end
    end

    # Returns [String] the name of the local file that the input stream reads, which a reader can read by its name,
    # such as a reader that only reads files, instead of a copy of the stream, see `Utils.local_file_name`.
    # Returns nil for any other stream.
    def self.input_file_name(input_stream)
      Utils.local_file_name(input_stream)
    end
    private_class_method :input_file_name

    # When a Writer supports streams, also allow it to simply support a file
    def self.file(file_name, **args, &block)
      ::File.open(file_name, "rb") { |file| stream(file, **args, &block) }
    end

    # For processing by either a file name or an open IO stream.
    def self.open(file_name_or_io, **args, &)
      file_name_or_io.is_a?(String) ? file(file_name_or_io, **args, &) : stream(file_name_or_io, **args, &)
    end

    attr_reader :input_stream

    def initialize(input_stream)
      @input_stream = input_stream
    end
  end
end
