# frozen_string_literal: true

module IOStreams
  module Zstd
    class Writer < IOStreams::Writer
      # The compression levels of zstd: from 1, the fastest, to 22, the best compression, 0 for its default, 3, and
      # negative levels, down to -131072, for even faster compression.
      LEVELS = (-131_072..22)

      def self.option_names
        %i[level]
      end

      # Raises ArgumentError for a level that zstd cannot compress with, such as 23, which zstd would silently lower, or
      # "19", and LoadError when the zstd library is not installed, see `IOStreams::Zstd.library`, so that they raise
      # before a path opens its output, which would replace an existing file, see `IOStreams::StreamFormat#check_stream`.
      def self.check(level: nil)
        Zstd.library.load_dependency
        return if level.nil? || (level.is_a?(Integer) && LEVELS.cover?(level))

        raise(ArgumentError, "Invalid zstd level #{level.inspect}: supply an Integer from 1, the fastest, to 22, the best " \
                             "compression, 0 for the default, or a negative level, down to -131072, for faster compression")
      end

      # Write to a stream, compressing with Zstandard.
      #
      # Parameters
      #   level: [Integer]
      #     Compression level, from 1 (fastest) to 22 (best compression),
      #     or a negative level for even faster compression.
      #     Default: 3
      #
      # The stream supplied to the block responds to the methods of an IO that write, see `IOStreams::Writable`.
      #
      # The output stream is not closed, since it belongs to the caller.
      #
      # The end of the zstd frame is written when the block returns, including when it leaves early, such as with
      # `break`. It is not written when the block raises, or its thread is killed, so that the output does not look like
      # a complete file of the partial data.
      def self.stream(output_stream, level: nil)
        check(level: level)

        encoder = Zstd.library.encoder(output_stream, level: level)
        Utils.finish_or_abort(finish: -> { encoder.finish }, abort: -> { encoder.close }) do
          yield Compressor.new(encoder)
        end
      end

      # Writes data to an encoder of the zstd library, as an IO, see `IOStreams::Writable`.
      class Compressor
        include Writable

        def initialize(encoder)
          @encoder = encoder
        end

        private

        # Returns [Integer] the number of bytes written, before compression.
        def write_data(data)
          @encoder.write(data) unless data.empty?
          data.bytesize
        end
      end
    end
  end
end
