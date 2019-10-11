module IOStreams
  class Reader
    # When a Reader does not support streams, we copy the stream to a local temp file
    # and then pass that filename in for this reader.
    def self.stream(input_stream, **args, &block)
      IOStreams::Paths::File.temp_file_name("iostreams_reader") do |temp_file_name|
        IOStreams.copy(input_stream, temp_file_name, target_options: {streams: []})
        file(temp_file_name, **args, &block)
      end
    end

    # When a Writer supports streams, also allow it to simply support a file
    def self.file(file_name, original_file_name: file_name, **args, &block)
      ::File.open(file_name, 'rb') { |file| stream(file, original_file_name: original_file_name, **args, &block) }
    end

    attr_reader :input_stream

    def initialize(input_stream)
      @input_stream = input_stream
    end
  end
end
