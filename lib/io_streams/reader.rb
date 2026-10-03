module IOStreams
  class Reader
    # Returns [Array<Symbol>] the names of the options this reader accepts,
    # or [nil] when the reader does not declare them.
    #
    # When declared, `IOStreams::Builder` rejects any other option before the reader is opened,
    # naming the direction an option belongs to when it is only valid for the other direction.
    def self.option_names
      nil
    end

    # When a Reader does not support streams, we copy the stream to a local temp file
    # and then pass that filename in for this reader.
    def self.stream(input_stream, **args, &block)
      Utils.temp_file_name("iostreams_reader") do |file_name|
        Utils.create_temp_file(file_name) { |target| ::IO.copy_stream(input_stream, target) }
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
