module IOStreams
  module Gzip
    class Writer < IOStreams::Writer
      def self.option_names
        %i[level]
      end

      # Write to a stream, compressing with GZip
      #
      # Parameters
      #   level: [Integer]
      #     Compression level, from 0 (no compression) to 9 (best compression).
      #     Default: Zlib::DEFAULT_COMPRESSION
      #
      # The output stream is not closed, since it belongs to the caller.
      def self.stream(output_stream, level: nil, &block)
        io = ::Zlib::GzipWriter.new(output_stream, level)
        block.call(io)
      ensure
        # Unlike #close, #finish does not close the output stream.
        io.finish if io && !io.closed?
      end
    end
  end
end
