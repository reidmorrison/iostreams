module IOStreams
  module SymmetricEncryption
    class Reader < IOStreams::Reader
      def self.option_names
        %i[buffer_size version]
      end

      # Also the writer's options, which reading does not need, since the header of the file records
      # how it was written, and the reader detects whether it has one.
      def self.valid_option_names
        option_names + %i[compress cipher_name header random_key random_iv]
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
