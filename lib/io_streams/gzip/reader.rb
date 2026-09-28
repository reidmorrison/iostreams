module IOStreams
  module Gzip
    class Reader < IOStreams::Reader
      def self.option_names
        []
      end

      # Read from a gzip stream, decompressing the contents as it is read
      def self.stream(input_stream)
        io = ::Zlib::GzipReader.new(input_stream)
        yield io
      ensure
        io&.close
      end
    end
  end
end
