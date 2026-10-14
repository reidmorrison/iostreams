# frozen_string_literal: true

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
      # The end of the zstd frame is written when the block returns, including when it leaves early, such as with
      # `break`. It is not written when the block raises, or its thread is killed, so that the output does not look like
      # a complete file of the partial data.
      def self.stream(output_stream, level: nil)
        encoder = Zstd.library.encoder(output_stream, level: level)
        Utils.finish_or_abort(finish: -> { encoder.finish }, abort: -> { encoder.close }) do
          yield Compressor.new(encoder)
        end
      end

      # Writes data to an encoder of the zstd library, as an IO.
      class Compressor
        def initialize(encoder)
          @encoder = encoder
        end

        # Returns [Integer] the number of bytes written, before compression.
        def write(data)
          data = data.to_s
          @encoder.write(data) unless data.empty?
          data.bytesize
        end

        def <<(data)
          write(data)
          self
        end
      end
    end
  end
end
