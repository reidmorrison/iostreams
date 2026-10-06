module IOStreams
  module Bzip2
    class Reader < IOStreams::Reader
      def self.option_names
        %i[autoclose first_only small]
      end

      # Also the writer's options, which reading does not need, since the block size is read from the
      # compressed data, and the work factor only applies when writing.
      def self.valid_option_names
        option_names + %i[block_size work_factor]
      end

      # Read from a Bzip2 stream, decompressing the contents as it is read
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
      def self.stream(input_stream, autoclose: false, first_only: false, small: false)
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
