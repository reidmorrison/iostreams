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
      def self.stream(input_stream, level: nil, &block)
        io = ::Zlib::GzipWriter.new(input_stream, level)
        block.call(io)
      ensure
        io&.close
      end
    end
  end
end
