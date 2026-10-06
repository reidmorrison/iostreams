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
    # or [nil] when the reader does not declare them.
    #
    # `IOStreams::Builder` rejects any other option before the reader is opened, naming the direction
    # an option belongs to when it is only valid for the other direction.
    #
    # One option hash is shared by the reader and the writer for a stream, so that the same path
    # can be written and then read. So this can also include the writer's options that reading does
    # not need, such as the compression level of a gzip file, which are ignored when reading. Only add
    # an option of the writer when ignoring it cannot change the result: a caller could expect any other
    # option to have an effect, so it must raise.
    def self.valid_option_names
      option_names
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
