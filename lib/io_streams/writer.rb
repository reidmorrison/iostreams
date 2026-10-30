module IOStreams
  class Writer
    # Answers the names of the options that this writer takes in IOStreams 3.0, and those that it replaces.
    extend Deprecation::OptionNames

    # Returns [Array<Symbol>] the names of the options this writer accepts,
    # or [nil] when the writer does not declare them.
    #
    # When declared, `IOStreams::Builder` rejects any other option before the writer is opened,
    # naming the direction an option belongs to when it is only valid for the other direction.
    def self.option_names
      nil
    end

    # Returns [Array<Symbol>] the names of the options whose values must not be displayed, such as a passphrase,
    # so that `#inspect` on a path does not display them, see `IOStreams::Extension#redact_options`.
    def self.sensitive_option_names
      []
    end

    # Returns [Array<Symbol>|nil] the methods that the stream that v3.0 supplies to a writer block, in place of the one
    # that this writer yields, answers, when it does not answer all of the methods of that one, otherwise nil, for a
    # writer whose stream answers the same methods in both versions, see `IOStreams::Reader.v3_stream_methods`.
    def self.v3_stream_methods(_reads_file)
      nil
    end

    # Returns [Hash<Symbol:String>|nil] what the application uses in place of each method of the stream that this writer
    # yields that v3.0 removes, see `IOStreams::Reader.v3_stream_advice`.
    def self.v3_stream_advice
      nil
    end

    # When a Writer does not support streams, we copy the stream to a local temp file
    # and then pass that filename in for this reader.
    def self.stream(output_stream, **args, &block)
      Utils.private_temp_file("iostreams_writer") do |file_name|
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
