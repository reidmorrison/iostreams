module IOStreams
  module SymmetricEncryption
    class Writer < IOStreams::Writer
      # Write to stream using Symmetric Encryption
      # By default the output stream is compressed.
      # If the input_stream is already compressed consider setting compress: false.
      def self.stream(input_stream, compress: true, **args, &block)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(SymmetricEncryption)

        ::SymmetricEncryption::Writer.open(input_stream, compress: compress, **args, &block)
      end

      # Write to stream using Symmetric Encryption
      # By default the output stream is compressed unless the file_name extension indicates the file is already compressed.
      def self.file(file_name, compress: nil, **args, &block)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(SymmetricEncryption)

        ::SymmetricEncryption::Writer.open(file_name, compress: compress, **args, &block)
      end
    end
  end
end
