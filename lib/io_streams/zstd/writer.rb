module IOStreams
  module Zstd
    class Writer < IOStreams::Writer
      def self.option_names
        %i[level]
      end

      # Write to a stream, compressing with Zstandard.
      #
      # Parameters
      #   level: [Integer]
      #     Compression level, from 1 (fastest) to 22 (best compression),
      #     or a negative level for even faster compression.
      #     Default: 3
      #
      # The output stream is not closed, since it belongs to the caller.
      #
      # `Zstd::StreamWriter` is not used, since the zstd-ruby README marks it as experimental:
      # https://github.com/SpringMT/zstd-ruby#stream-writer-and-reader-wrapper
      # It also flushes a block on every write, which compresses small writes, such as lines, poorly.
      def self.stream(output_stream, level: nil)
        Utils.load_soft_dependency("zstd-ruby", "Zstandard") unless defined?(::Zstd::StreamingCompress)

        io     = Compressor.new(output_stream, level: level)
        result = yield io
        io.finish
        result
      end

      # Compresses the data written to it, writing the compressed data to the output stream.
      class Compressor
        def initialize(output_stream, level: nil)
          @output_stream = output_stream
          @zstd          = level.nil? ? ::Zstd::StreamingCompress.new : ::Zstd::StreamingCompress.new(level: level)
        end

        # Returns [Integer] the number of bytes written, before compression.
        def write(data)
          data       = data.to_s
          compressed = @zstd.compress(data)
          @output_stream.write(compressed) unless compressed.empty?
          data.bytesize
        end

        def <<(data)
          write(data)
          self
        end

        # Writes the end of the zstd frame, without closing the output stream, which belongs to the caller.
        def finish
          @output_stream.write(@zstd.finish)
        end
      end
    end
  end
end
