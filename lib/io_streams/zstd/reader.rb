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
      # The stream supplied to the block responds to #read, #readpartial and #eof?.
      def self.stream(input_stream)
        decoder = Zstd.library.decoder(input_stream)
        yield Decompressor.new(decoder)
      ensure
        decoder&.close
      end

      # Returns the data from a decoder of the zstd library as an IO, holding the data decompressed
      # but not yet returned.
      class Decompressor
        def initialize(decoder)
          @decoder = decoder
          @buffer  = String.new(encoding: Encoding::BINARY)
          @eof     = false
        end

        # Returns [String] up to `length` bytes, or the rest of the stream when `length` is nil.
        # Returns [nil] at the end of the stream when `length` is supplied.
        def read(length = nil, outbuf = nil)
          data = length.nil? ? read_all : read_upto(length)
          return data unless outbuf

          data.nil? ? outbuf.clear : outbuf.replace(data)
          data && outbuf
        end

        # Raises [EOFError] at the end of the stream.
        def readpartial(maxlen, outbuf = nil)
          read(maxlen, outbuf) || raise(EOFError, "end of file reached")
        end

        def eof?
          fill(1)
          @buffer.empty?
        end

        alias eof eof?

        private

        def read_all
          fill(nil)
          @buffer.slice!(0, @buffer.bytesize)
        end

        def read_upto(length)
          return String.new(encoding: Encoding::BINARY) if length.zero?

          fill(length)
          @buffer.empty? ? nil : @buffer.slice!(0, length)
        end

        # Decompresses until the buffer holds `length` bytes, or the whole stream when `length` is nil.
        def fill(length)
          until @eof || (length && @buffer.bytesize >= length)
            block = @decoder.read_block
            if block.nil?
              @eof = true
            else
              @buffer << block
            end
          end
        end
      end
    end
  end
end
