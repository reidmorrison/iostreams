# frozen_string_literal: true

require "zlib"

module IOStreams
  module Gzip
    class Writer < IOStreams::Writer
      # The compression levels of zlib: -1 for its default, and from 0, no compression, to 9, the best compression.
      LEVELS = (::Zlib::DEFAULT_COMPRESSION..::Zlib::BEST_COMPRESSION)

      def self.option_names
        %i[level]
      end

      # Raises ArgumentError for a level that zlib cannot compress with, such as 10, so that it raises before a path opens
      # its output, which would replace an existing file, see `IOStreams::StreamFormat#check_stream`.
      def self.check(level: nil)
        return if level.nil? || (level.is_a?(Integer) && LEVELS.cover?(level))

        raise(ArgumentError, "Invalid gzip level #{level.inspect}: supply an Integer from 0, no compression, to 9, the " \
                             "best compression, or -1 for the default")
      end

      # Write to a stream, compressing with GZip
      #
      # Parameters
      #   level: [Integer]
      #     Compression level, from 0 (no compression) to 9 (best compression).
      #     Default: Zlib::DEFAULT_COMPRESSION
      #
      # The stream supplied to the block is the `Zlib::GzipWriter`, with the methods of an IO that write, see
      # `IOStreams::Writable`, since on JRuby its `#write` takes only one argument.
      #
      # The output stream is not closed, since it belongs to the caller.
      #
      # The gzip trailer is written when the block returns, including when it leaves early, such as with `break`, so
      # that what was written is a complete gzip file. It is not written when the block raises, or its thread is killed,
      # so that the output does not look like a complete file of the partial data, see `IOStreams::AbortableOutput`.
      def self.stream(output_stream, level: nil)
        check(level: level)

        output = AbortableOutput.new(output_stream)
        io     = ::Zlib::GzipWriter.new(output, level)
        # Unlike #close, #finish does not close the output stream.
        finish = -> { io.finish unless io.closed? }
        abort  = lambda do
          output.discard
          finish.call
        end
        Utils.finish_or_abort(finish: finish, abort: abort) { yield(Writable::Adapter.new(io)) }
      end
    end
  end
end
