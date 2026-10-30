module IOStreams
  module Gzip
    class Reader < IOStreams::Reader
      def self.option_names
        []
      end

      # The methods that the stream that v3.0 supplies to a reader block for gzip answers: those of an IO that read, and
      # #close, see .v3_stream_methods.
      V3_METHODS = [*V3_READ_METHODS, :close].freeze
      private_constant :V3_METHODS

      # Returns [Array<Symbol>] the methods that the stream that v3.0 supplies to a reader block, in place of the
      # `Zlib::GzipReader` that this reader yields, answers, see `IOStreams::Reader.v3_stream_methods`.
      def self.v3_stream_methods(_reads_file)
        V3_METHODS
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
