module IOStreams
  class Writer
    # Returns [Array<Symbol>] the names of the options this writer accepts,
    # or [nil] when the writer does not declare them.
    #
    # When declared, `IOStreams::Builder` rejects any other option before the writer is opened,
    # naming the direction an option belongs to when it is only valid for the other direction.
    def self.option_names
      nil
    end

    # When a Writer does not support streams, we copy the stream to a local temp file
    # and then pass that filename in for this reader.
    def self.stream(output_stream, **args, &block)
      Utils.temp_file_name("iostreams_writer") do |file_name|
        count = file(file_name, **args, &block)
        ::File.open(file_name, "rb") { |source| ::IO.copy_stream(source, output_stream) }
        count
      end
    end

    # When a Writer supports streams, also allow it to simply support a file
    def self.file(file_name, **args, &block)
      ::File.open(file_name, "wb") { |file| stream(file, **args, &block) }
    end

    # For processing by either a file name or an open IO stream.
    def self.open(file_name_or_io, **args, &)
      file_name_or_io.is_a?(String) ? file(file_name_or_io, **args, &) : stream(file_name_or_io, **args, &)
    end

    attr_reader :output_stream

    def initialize(output_stream)
      @output_stream = output_stream
    end
  end
end
