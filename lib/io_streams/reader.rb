module IOStreams
  class Reader
    # Answers the names of the options that this reader takes in IOStreams 3.0, and those that it replaces.
    extend Deprecation::OptionNames

    # Returns [Array<Symbol>] the names of the options this reader accepts,
    # or [nil] when the reader does not declare them.
    #
    # When declared, `IOStreams::Builder` rejects any other option before the reader is opened,
    # naming the direction an option belongs to when it is only valid for the other direction.
    def self.option_names
      nil
    end

    # Returns [Array<Symbol>] the names of the options whose values must not be displayed, such as a passphrase,
    # so that `#inspect` on a path does not display them, see `IOStreams::Extension#redact_options`.
    def self.sensitive_option_names
      []
    end

    # Returns [Symbol|nil] the tabular format of the text that this reader turns its data into, such as `:csv` for a
    # spreadsheet, otherwise nil, for a reader whose data is the text, such as gzip, see
    # `IOStreams::Builder#text_format`.
    def self.text_format
      nil
    end

    # The methods of an IO that read, which every stream that v3.0 supplies to a reader block answers, see
    # .v3_stream_methods.
    V3_READ_METHODS = %i[read readpartial gets readline readlines each_line each eof? eof closed?].freeze

    # Returns [Array<Symbol>|nil] the methods that the stream that v3.0 supplies to a reader block, in place of the one
    # that this reader yields, answers, when it does not answer all of the methods of that one, such as when it is the
    # reader of a gem, otherwise nil, for a reader that yields the same kind of stream in both versions, see
    # `IOStreams::Builder#v3_stream`.
    #
    # Parameters:
    #   options: [Hash]
    #     The options that this reader is opened with, such as `verify_first: true` for PGP, see
    #     `IOStreams::Pgp::Reader.v3_stream_methods`.
    #
    # Yields, for a reader whose stream depends on it, to ask whether this reader reads a regular local file in v3.0,
    # rather than another stream, an IO that is not a file, or the object of an S3 or HTTP path, which v3.0 reads without
    # a temp file. The block answers true or false.
    def self.v3_stream_methods(_options)
      nil
    end

    # Returns [Hash<Symbol:String>|nil] what the application uses in place of each method of the stream that this reader
    # yields that v3.0 removes, when it is not the methods that the stream of v3.0 answers, see .v3_stream_methods, such as
    # a setting of the path, otherwise nil, see `IOStreams::Builder#v3_stream`.
    def self.v3_stream_advice
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
