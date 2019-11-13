module IOStreams
  module SymmetricEncryption
    class Reader < IOStreams::Reader
      # read from a file/stream using Symmetric Encryption
      def self.stream(input_stream, **args, &block)
        unless defined?(SymmetricEncryption)
          Utils.load_soft_dependency('symmetric-encryption', '.enc streaming')
        end

        ::SymmetricEncryption::Reader.open(input_stream, **args, &block)
      end
    end
  end
end
