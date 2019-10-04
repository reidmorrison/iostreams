module IOStreams
  module SymmetricEncryption
    class Reader < IOStreams::Reader
      # read from a file/stream using Symmetric Encryption
      def self.stream(input_stream, **args, &block)
        Utils.load_dependency('symmetric-encryption', '.enc streaming') unless defined?(SymmetricEncryption)

        ::SymmetricEncryption::Reader.open(input_stream, **args, &block)
      end
    end
  end
end
