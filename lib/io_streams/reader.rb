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

    # Returns [Array<Symbol>] the names of the options that this reader takes in IOStreams 3.0 too, or [nil] when
    # they are not known, since it does not declare its options. `#option`, `#stream` and `#option_or_stream` report
    # a deprecation warning for an option that neither the reader nor the writer of a stream knows, see
    # `IOStreams::Extension#unknown_option_names`, since IOStreams 3.0 raises ArgumentError for it when it is set.
    #
    # By default the options that it declares, see .option_names, other than those that it replaces, see
    # .replaced_option_names.
    def self.known_option_names
      names = option_names
      names && (names - replaced_option_names.keys)
    end

    # Returns [Hash<Symbol, Symbol>] the deprecated options that this reader still takes, which IOStreams 3.0 does
    # not, with the option that replaces each, which `#option`, `#stream` and `#option_or_stream` name in their
    # deprecation warning, see `IOStreams::Extension#replaced_option_names`. None by default.
    def self.replaced_option_names
      {}
    end

    # Returns [Array<Symbol>] the names of the options whose values must not be displayed, such as a passphrase,
    # so that `#inspect` on a path does not display them, see `IOStreams::Extension#redact_options`.
    def self.sensitive_option_names
      []
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
