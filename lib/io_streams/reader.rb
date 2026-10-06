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
    # or [nil] to accept the options of both the reader and the writer registered for the stream.
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

    # When a Reader does not support streams, we copy the stream to a local temp file
    # and then pass that filename in for this reader.
    def self.stream(input_stream, **args, &block)
      Utils.private_temp_file("iostreams_reader") do |file_name|
        ::File.open(file_name, "wb") { |target| ::IO.copy_stream(input_stream, target) }
        file(file_name, **args, &block)
      end
    end

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
