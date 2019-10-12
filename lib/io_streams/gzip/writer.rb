module IOStreams
  module Gzip
    class Writer < IOStreams::Writer
      # Write to a stream, compressing with GZip
      def self.stream(input_stream, original_file_name: nil, &block)
        io = ::Zlib::GzipWriter.new(input_stream)
        block.call(io)
      ensure
        io&.close
      end
    end
  end
end
