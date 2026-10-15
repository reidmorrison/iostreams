# frozen_string_literal: true

require "delegate"

module IOStreams
  module Bzip2
    class Reader < IOStreams::Reader
      def self.option_names
        %i[autoclose first_only small]
      end

      # Returns [Module] `IOStreams::Errors::Corrupt` for an exception that bzip2-ffi raises for data that is not bzip2,
      # or is damaged or cut short: `Bzip2::FFI::Error::DataError`, including its `MagicDataError`, and
      # `Bzip2::FFI::Error::UnexpectedEofError`, see `IOStreams::Reader.failure_kind`.
      def self.failure_kind(exception)
        return unless defined?(::Bzip2::FFI::Error)

        corrupt = [::Bzip2::FFI::Error::DataError, ::Bzip2::FFI::Error::UnexpectedEofError]
        Errors::Corrupt if corrupt.any? { |error_class| exception.is_a?(error_class) }
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
      #
      # The stream supplied to the block responds to #read, #readpartial and #eof?, see `IOStreams::BlockReader`.
      #
      # Raises the exception of bzip2-ffi, tagged as `IOStreams::Errors::Corrupt`, for data that is not bzip2, or is
      # damaged or cut short, see .failure_kind, and `IOStreams::Errors::StreamFailure`, tagged the same way, for empty
      # data, see Decompressor.
      def self.stream(input_stream, autoclose: false, first_only: false, small: false)
        Utils.load_soft_dependency("bzip2-ffi", "Bzip2", "bzip2/ffi") unless defined?(::Bzip2::FFI)

        begin
          input  = Input.new(input_stream)
          reader = ::Bzip2::FFI::Reader.new(input, autoclose: autoclose, first_only: first_only, small: small)
          yield Decompressor.new(reader, input)
        ensure
          reader&.close
        end
      end

      # The input stream of bzip2-ffi, which notes whether any data was read from it. Every other method is the input
      # stream's own, such as `#close`, which bzip2-ffi calls when `autoclose: true`.
      class Input < SimpleDelegator
        def read(...)
          data = __getobj__.read(...)
          @read ||= !data.nil? && !data.empty?
          data
        end

        # Returns [true|false] whether any data was read from the input stream.
        def read?
          @read || false
        end
      end

      # Reads the data that bzip2-ffi decompresses a block at a time, see `IOStreams::BlockReader`.
      #
      # Raises for input without any data, which bzip2-ffi reads as empty, while `bzip2 -d` rejects it, since bzip2 data
      # always starts with its header, even when it holds no data.
      class Decompressor < BlockReader
        def initialize(reader, input)
          super(reader, failures: Reader)
          @input = input
        end

        private

        def next_chunk
          chunk = super
          return chunk if chunk || @input.read?

          raise(Errors::Corrupt.tag(Errors::StreamFailure.new("The bzip2 data is empty")))
        end
      end
    end
  end
end
