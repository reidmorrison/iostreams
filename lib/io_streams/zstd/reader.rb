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
      #
      # `Zstd::StreamReader` is not used, since the zstd-ruby README marks it as experimental:
      # https://github.com/SpringMT/zstd-ruby#stream-writer-and-reader-wrapper
      # It also requires a length to #read, and raises at the end of the stream instead of returning nil.
      def self.stream(input_stream)
        Utils.load_soft_dependency("zstd-ruby", "Zstandard") unless defined?(::Zstd::StreamingDecompress)

        yield Decompressor.new(input_stream)
      end

      # Decompresses the input stream as it is read, holding the data decompressed but not yet returned.
      class Decompressor
        BLOCK_SIZE = 65_536

        def initialize(input_stream)
          @input_stream = input_stream
          @zstd         = ::Zstd::StreamingDecompress.new
          @buffer       = String.new(encoding: Encoding::BINARY)
          @input_eof    = false
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

        # Decompresses input until the buffer holds `length` bytes, or the whole stream when `length` is nil.
        def fill(length)
          until @input_eof || (length && @buffer.bytesize >= length)
            block = @input_stream.read(BLOCK_SIZE)
            if block.nil?
              @input_eof = true
            else
              @buffer << @zstd.decompress(block)
            end
          end
        end
      end
    end
  end
end
