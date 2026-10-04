module IOStreams
  module Bzip2
    class Reader < IOStreams::Reader
      OPTION_NAMES = %i[autoclose first_only small].freeze

      # Not declared until v3.0, so that an unknown option logs a warning instead of raising `ArgumentError`.
      def self.option_names
        nil
      end

      # Read from a Bzip2 stream, decompressing the contents as it is read
      #
      # Any other option is ignored and logs a warning. It will raise `ArgumentError` in v3.0.
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
        Utils.warn_unknown_options(unknown, :bz2, "reading", OPTION_NAMES)
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
