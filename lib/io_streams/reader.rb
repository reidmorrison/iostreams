module IOStreams
  class Reader
    # When a Reader does not support streams, we copy the stream to a local temp file
    # and then pass that filename in for this reader.
    def self.stream(input_stream, **args, &block)
      IOStreams::File::Path.temp_file_name('iostreams_reader') do |temp_file_name|
        IOStreams.copy(input_stream, temp_file_name, target_options: {streams: []})
        file(temp_file_name, **args, &block)
      end
    end

    attr_reader :input_stream

    def initialize(input_stream)
      @input_stream = input_stream
    end
  end
end
