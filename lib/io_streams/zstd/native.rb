module IOStreams
  module Zstd
    # Zstandard with the `zstd-ruby` gem, a C extension.
    #
    # Uses `Zstd::StreamingDecompress` and `Zstd::StreamingCompress`, since the zstd-ruby README
    # marks `Zstd::StreamReader` and `Zstd::StreamWriter` as experimental:
    # https://github.com/SpringMT/zstd-ruby#stream-writer-and-reader-wrapper
    # `Zstd::StreamReader#read` also requires a length, and raises at the end of the stream instead of
    # returning nil, and `Zstd::StreamWriter` flushes a block on every write, which compresses small writes,
    # such as lines, poorly.
    module Native
      BLOCK_SIZE = 65_536

      # Returns [Decoder] that decompresses the input stream.
      def self.decoder(input_stream)
        load_dependency
        Decoder.new(input_stream)
      end

      # Returns [Encoder] that writes the data compressed to the output stream.
      def self.encoder(output_stream, level: nil)
        load_dependency
        Encoder.new(output_stream, level: level)
      end

      def self.load_dependency
        Utils.load_soft_dependency("zstd-ruby", "Zstandard") unless defined?(::Zstd::StreamingCompress)
      end

      class Decoder
        def initialize(input_stream)
          @input_stream = input_stream
          @zstd         = ::Zstd::StreamingDecompress.new
        end

        # Returns [String] the data decompressed from the next block of the input stream, which can be empty,
        # or [nil] at the end of the input stream.
        #
        # A frame cut short at the end of the input stream is not detected, since `zstd-ruby` does not report it.
        def read_block
          block = @input_stream.read(BLOCK_SIZE)
          block && @zstd.decompress(block)
        end

        def close
        end
      end

      class Encoder
        def initialize(output_stream, level: nil)
          @output_stream = output_stream
          @zstd          = level.nil? ? ::Zstd::StreamingCompress.new : ::Zstd::StreamingCompress.new(level: level)
        end

        def write(data)
          compressed = @zstd.compress(data)
          @output_stream.write(compressed) unless compressed.empty?
        end

        # Writes the end of the zstd frame, without closing the output stream, which belongs to the caller.
        def finish
          @output_stream.write(@zstd.finish)
        end

        # Nothing to free, since zstd-ruby frees the compression context when it is garbage collected.
        def close
        end
      end
    end
  end
end
