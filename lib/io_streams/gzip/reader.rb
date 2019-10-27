module IOStreams
  module Gzip
    class Reader < IOStreams::Reader
      # Read from a gzip stream, decompressing the contents as it is read
      def self.stream(input_stream, original_file_name: nil, &block)
        io = ::Zlib::GzipReader.new(input_stream)
        block.call(io)
      ensure
        io&.close
      end
    end
  end
end
