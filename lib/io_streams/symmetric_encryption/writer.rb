module IOStreams
  module SymmetricEncryption
    class Writer < IOStreams::Writer
      def self.option_names
        %i[compress version cipher_name header random_key random_iv]
      end

      # Also how much of the file to read at a time, which writing does not use.
      def self.valid_option_names
        option_names + %i[buffer_size]
      end

      # Write to stream using Symmetric Encryption
      # By default the output stream is compressed.
      # If the input_stream is already compressed consider setting compress: false.
      #
      # Like `SymmetricEncryption::Writer.open`, but does not close the output stream, which belongs to the caller.
      def self.stream(output_stream, compress: true, **args)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(SymmetricEncryption)

        begin
          writer = ::SymmetricEncryption::Writer.new(output_stream, compress: compress, **args)
          io     = compress ? ::Zlib::GzipWriter.new(writer) : writer
          yield io
        ensure
          io.finish if io.is_a?(::Zlib::GzipWriter) && !io.closed?
          writer&.close(false)
        end
      end

      # Write to stream using Symmetric Encryption
      # By default the output stream is compressed unless the file_name extension indicates the file is already compressed.
      def self.file(file_name, compress: nil, **args, &)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(SymmetricEncryption)

        ::SymmetricEncryption::Writer.open(file_name, compress: compress, **args, &)
      end
    end
  end
end
