module IOStreams
  module Bzip2
    class Writer < IOStreams::Writer
      OPTION_NAMES = %i[autoclose block_size work_factor].freeze

      # Not declared until v3.0, so that an unknown option logs a warning instead of raising `ArgumentError`.
      def self.option_names
        nil
      end

      # Returns [Array<Symbol>] the options that this class takes, which v3.0 declares as its `option_names`, so that
      # an option of this class supplied to the reader is not reported as deprecated, since v3.0 accepts it there, and
      # ignores it, see `IOStreams::Utils.warn_unknown_options`.
      def self.known_option_names
        OPTION_NAMES
      end

      # Write to a stream, compressing with Bzip2
      #
      # Any other option is ignored, and logs a warning. One that the reader does not take either also reports a
      # deprecation warning, since it will raise `ArgumentError` in v3.0.
      #
      # Parameters are passed through to `Bzip2::FFI::Writer`:
      #   autoclose: [true|false]
      #     Close the output stream when the writer is closed.
      #     Default: false
      #
      #   block_size: [Integer]
      #     Compression block size, from 1 (100k) to 9 (900k).
      #     Default: 9
      #
      #   work_factor: [Integer]
      #     How much effort to spend on highly repetitive input before falling back
      #     to a slower algorithm, from 0 to 250. 0 uses the libbz2 default.
      #     Default: 0
      def self.stream(input_stream, autoclose: false, block_size: nil, work_factor: nil, **unknown)
        Utils.warn_unknown_options(unknown, :bz2, :writer, OPTION_NAMES)
        Utils.load_soft_dependency("bzip2-ffi", "Bzip2", "bzip2/ffi") unless defined?(::Bzip2::FFI)

        begin
          io = ::Bzip2::FFI::Writer.new(input_stream, autoclose: autoclose, block_size: block_size, work_factor: work_factor)
          yield io
        ensure
          io&.close
        end
      end
    end
  end
end
