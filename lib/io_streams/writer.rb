module IOStreams
  class Writer
    # When a Writer does not support streams, we copy the stream to a local temp file
    # and then pass that filename in for this reader.
    def self.stream(output_stream, **args, &block)
      IOStreams::File::Path.temp_file_name('iostreams_writer') do |temp_file_name|
        write_file(temp_file_name, **args, &block)
        IOStreams.copy(temp_file_name, output_stream, source_options: {streams: []})
      end
    end

    attr_reader :output_stream

    def initialize(output_stream)
      @output_stream = output_stream
    end
  end
end
