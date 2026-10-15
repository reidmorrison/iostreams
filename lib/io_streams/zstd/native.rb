# frozen_string_literal: true

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

      # Loads the `zstd-ruby` gem, from version 2.0.0, which added `Zstd::StreamingDecompress#decompress_with_pos`.
      def self.load_dependency
        Utils.load_soft_dependency("zstd-ruby", "Zstandard") unless defined?(::Zstd::StreamingCompress)
      end

      class Decoder
        def initialize(input_stream)
          @input_stream = input_stream
          @zstd         = ::Zstd::StreamingDecompress.new
          # The input that zstd has not read yet.
          @input        = String.new(encoding: Encoding::BINARY)
          @end_of_input = false
          @read         = false
          # Follows the frames of the input, since `zstd-ruby` does not report a frame that it ends within.
          @frames       = Frames.new
        end

        # Returns [String] the next data decompressed, at most one block of zstd, 128KB, however well the data
        # compresses, or [nil] at the end of the input stream.
        #
        # `#decompress_with_pos` fills one output buffer of zstd, and returns how much of the input it read, so that
        # the rest is decompressed by the next call, where `#decompress` returns all of the data of the input block at
        # once, which could be gigabytes for 64KB of data that compresses well.
        #
        # Raises [RuntimeError] tagged as `IOStreams::Errors::Corrupt` for data that is not zstd, or a frame cut short at
        # the end of the input stream, see `Zstd.corrupt`.
        def read_block
          loop do
            read_input if @input.empty? && !@end_of_input
            data, read = decompress
            @input     = @input.byteslice(read..)
            return data unless data.empty?
            # Without any input to read, zstd has also written out all of the data it holds.
            return if @end_of_input && @input.empty?
            # zstd reads some of the input whenever it writes no data, so this would loop forever.
            raise(Zstd.corrupt("none of the input was read")) if read.zero? && !@input.empty?
          end
        end

        def close
        end

        private

        # Returns [Array(String, Integer)] the data that zstd decompressed from the input, and how much of the input it
        # read. Tags the RuntimeError that `zstd-ruby` raises for data that is not zstd as `IOStreams::Errors::Corrupt`.
        def decompress
          @zstd.decompress_with_pos(@input)
        rescue RuntimeError => e
          raise(Errors::Corrupt.tag(e))
        end

        # Raises [RuntimeError] at the end of an input stream without any data, which is not zstd, like `zstd -d`, or
        # that ends within a frame, with the message of zstd-jni on JRuby, see `Zstd::Frames`.
        def read_input
          block = @input_stream.read(BLOCK_SIZE)
          if block.nil?
            raise(Zstd.corrupt("the data is empty")) unless @read
            raise(Zstd.corrupt("Truncated source")) unless @frames.complete?

            @end_of_input = true
          else
            @read ||= !block.empty?
            @frames << block
            @input = block
          end
        end
      end

      # Writes zstd frames without a checksum of their content, since `zstd-ruby`, upto version 2.0.10 at least, has no
      # option to write one. Reading checks the checksum of a frame that has one, such as a frame that the zstd command
      # or zstd-jni on JRuby wrote.
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

        # Ends writing without the end of the zstd frame, when writing did not finish. Nothing to free, since zstd-ruby
        # frees the compression context when it is garbage collected.
        def close
        end
      end
    end
  end
end
