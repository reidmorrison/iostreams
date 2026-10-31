module IOStreams
  module Bzip2
    class Reader < IOStreams::Reader
      OPTION_NAMES = %i[autoclose first_only small].freeze

      # Not declared until v3.0, so that an unknown option logs a warning instead of raising `ArgumentError`.
      def self.option_names
        nil
      end

      # Returns [Array<Symbol>] the options that this class takes, which v3.0 declares as its `option_names`, see
      # `IOStreams::Deprecation::OptionNames#known_option_names`, so that an option that neither it nor the writer takes
      # is reported as deprecated when it is set, while one of the writer is not, since v3.0 accepts it, and ignores it,
      # and so that a path opens it with these alone, and logs the others, see `IOStreams::Builder#taken_options`.
      def self.known_option_names
        OPTION_NAMES
      end

      # Returns [Array<Symbol>] the methods that the stream that v3.0 supplies to a reader block, in place of the
      # `Bzip2::FFI::Reader` that this reader yields, answers: those of an IO that read, see
      # `IOStreams::Reader.v3_stream_methods`.
      def self.v3_stream_methods(_options)
        V3_READ_METHODS
      end

      # Read from a Bzip2 stream, decompressing the contents as it is read
      #
      # Any other option is ignored, and logs a warning. One that the writer does not take either also reports a
      # deprecation warning when it is set, see .known_option_names, since it will raise `ArgumentError` in v3.0.
      #
      # Parameters are passed through to `Bzip2::FFI::Reader`:
      #   autoclose: [true|false]
      #     Close the input stream when the reader is closed.
      #     Default: false
      #
      #   first_only: [true|false]
      #     Only decompress the first of any consecutive bzip2 structures in the input.
      #     Default: false
      #
      #   small: [true|false]
      #     Use an alternative decompression algorithm that uses less memory but is slower.
      #     Default: false
      def self.stream(input_stream, autoclose: false, first_only: false, small: false, **unknown)
        Utils.warn_unknown_options(unknown, :bz2, :reader, OPTION_NAMES)
        Utils.load_soft_dependency("bzip2-ffi", "Bzip2", "bzip2/ffi") unless defined?(::Bzip2::FFI)

        begin
          io = ::Bzip2::FFI::Reader.new(input_stream, autoclose: autoclose, first_only: first_only, small: small)
          yield io
        ensure
          io&.close
        end
      end
    end
  end
end
