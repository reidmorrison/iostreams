module IOStreams
  module SymmetricEncryption
    class Reader < IOStreams::Reader
      def self.option_names
        %i[buffer_size version]
      end

      # Returns [Array<Symbol>] the methods that the stream that v3.0 supplies to a reader block, in place of the one that
      # this reader yields, a `Zlib::GzipReader` for a compressed file, otherwise a `SymmetricEncryption::Reader`,
      # answers: those of an IO that read, see `IOStreams::Reader.v3_stream_methods`. The stream of a compressed file
      # also answers #close in v3.0, which the block need not call, since the stream is closed once the block returns.
      def self.v3_stream_methods(_reads_file)
        V3_READ_METHODS
      end

      # read from a file/stream using Symmetric Encryption
      def self.stream(input_stream, **args, &)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(SymmetricEncryption)

        ::SymmetricEncryption::Reader.open(input_stream, **args, &)
      end
    end
  end
end
