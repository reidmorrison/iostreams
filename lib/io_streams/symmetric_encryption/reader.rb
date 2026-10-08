require "delegate"

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
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(::SymmetricEncryption)

        begin
          reader = ::SymmetricEncryption::Reader.new(input_stream, buffer_size: buffer_size, **args)
          # Bytes, like every other stream, rather than the external encoding that `Zlib::GzipReader#read` returns,
          # or the UTF-8 that the uncompressed reader returns on some Ruby versions.
          io     = if !reader.eof? && reader.compressed?
                     ::Zlib::GzipReader.new(reader, external_encoding: Encoding::BINARY)
                   else
                     Bytes.new(reader)
                   end
          yield io
        ensure
          io.finish if io.is_a?(::Zlib::GzipReader) && !io.closed?
          reader&.close(false)
        end
      end

      # The uncompressed reader, whose `#read` returns bytes. `SymmetricEncryption::Reader#read`
      # builds its result in a String literal, so on some Ruby versions it is tagged UTF-8.
      # Every other method, such as `#gets`, is the reader's own.
      class Bytes < SimpleDelegator
        def read(...)
          __getobj__.read(...)&.force_encoding(Encoding::BINARY)
        end
      end
    end
  end
end
