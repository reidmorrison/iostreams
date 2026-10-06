module IOStreams
  module SymmetricEncryption
    class Reader < IOStreams::Reader
      def self.option_names
        %i[buffer_size version]
      end

      # read from a file/stream using Symmetric Encryption
      #
      # Like `SymmetricEncryption::Reader.open`, but does not close the input stream, which belongs to the caller.
      def self.stream(input_stream, buffer_size: 16_384, **args)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(SymmetricEncryption)

        begin
          reader = ::SymmetricEncryption::Reader.new(input_stream, buffer_size: buffer_size, **args)
          io     = !reader.eof? && reader.compressed? ? ::Zlib::GzipReader.new(reader) : reader
          yield io
        ensure
          io.finish if io.is_a?(::Zlib::GzipReader) && !io.closed?
          reader&.close(false)
        end
      end
    end
  end
end
