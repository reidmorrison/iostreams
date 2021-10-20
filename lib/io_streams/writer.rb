module IOStreams
  class Writer
    # When a Writer does not support streams, we copy the stream to a local temp file
    # and then pass that filename in for this reader.
    def self.stream(output_stream, original_file_name: nil, **args, &block)
      Utils.temp_file_name("iostreams_writer") do |file_name|
        count = file(file_name, original_file_name: original_file_name, **args, &block)
        ::File.open(file_name, "rb") { |source| ::IO.copy_stream(source, output_stream) }
        count
      end
    end

    # When a Writer supports streams, also allow it to simply support a file
    def self.file(file_name, original_file_name: file_name, **args, &block)
      ::File.open(file_name, "wb") { |file| stream(file, original_file_name: original_file_name, **args, &block) }
    end

    # For processing by either a file name or an open IO stream.
    def self.open(file_name_or_io, **args, &block)
      file_name_or_io.is_a?(String) ? file(file_name_or_io, **args, &block) : stream(file_name_or_io, **args, &block)
    end

    attr_reader :output_stream

    def initialize(output_stream)
      @output_stream = output_stream
    end
  end
end
