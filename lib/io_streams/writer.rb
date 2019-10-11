module IOStreams
  class Writer
    # When a Writer does not support streams, we copy the stream to a local temp file
    # and then pass that filename in for this reader.
    def self.stream(output_stream, original_file_name: nil, **args, &block)
      IOStreams::Paths::File.temp_file_name("iostreams_writer") do |temp_file_name|
        file(temp_file_name, original_file_name: original_file_name, **args, &block)
        IOStreams.copy(temp_file_name, output_stream, source_options: {streams: []})
      end
    end

    # When a Writer supports streams, also allow it to simply support a file
    def self.file(file_name, original_file_name: file_name, **args, &block)
      ::File.open(file_name, "wb") { |file| stream(file, original_file_name: original_file_name, **args, &block) }
    end

    attr_reader :output_stream

    def initialize(output_stream)
      @output_stream = output_stream
    end
  end
end
