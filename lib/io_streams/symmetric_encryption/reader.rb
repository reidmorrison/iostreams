module IOStreams
  module SymmetricEncryption
    class Reader < IOStreams::Reader
      # read from a file/stream using Symmetric Encryption
      def self.stream(input_stream, **args, &)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(SymmetricEncryption)

        # compress is a writer-only option; readers detect compression from the header.
        args.delete(:compress)
        ::SymmetricEncryption::Reader.open(input_stream, **args, &)
      end
    end
  end
end
