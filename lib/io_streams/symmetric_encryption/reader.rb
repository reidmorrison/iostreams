module IOStreams
  module SymmetricEncryption
    class Reader < IOStreams::Reader
      # read from a file/stream using Symmetric Encryption
      def self.stream(input_stream, **args, &)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(SymmetricEncryption)

        ::SymmetricEncryption::Reader.open(input_stream, **args, &)
      end
    end
  end
end
