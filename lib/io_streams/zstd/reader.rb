# frozen_string_literal: true

module IOStreams
  module Zstd
    class Reader < IOStreams::Reader
      def self.option_names
        []
      end

      # Read from a Zstandard stream, decompressing the contents as it is read.
      #
      # A zstd file can contain several frames one after the other, for example when zstd files
      # are concatenated, and like `zstd -d` the contents of every frame are returned.
      #
      # The stream supplied to the block responds to #read, #readpartial and #eof?, see `IOStreams::ChunkReader`.
      def self.stream(input_stream)
        io = Decompressor.new(Zstd.library.decoder(input_stream))
        yield io
      ensure
        io&.close
      end

      # Returns the data from a decoder of the zstd library as an IO, holding the block that the decoder
      # decompressed last.
      class Decompressor
        include ChunkReader

        def initialize(decoder)
          @decoder = decoder
          @closed  = false
        end

        # Frees the decoder, without closing the input stream, which belongs to the caller.
        def close
          @decoder.close
          @closed = true
        end

        def closed?
          @closed
        end

        private

        # Returns [String] the next block of data decompressed, or nil at the end of the stream, see
        # `IOStreams::ChunkReader`.
        def next_chunk
          @decoder.read_block
        end
      end
    end
  end
end
