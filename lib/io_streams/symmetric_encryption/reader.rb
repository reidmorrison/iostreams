# frozen_string_literal: true

module IOStreams
  module SymmetricEncryption
    class Reader < IOStreams::Reader
      def self.option_names
        %i[buffer_size version]
      end

      # read from a file/stream using Symmetric Encryption
      #
      # Like `SymmetricEncryption::Reader.open`, but does not close the input stream, which belongs to the caller.
      #
      # Compressed data is decompressed by the gzip stream, see `IOStreams::Gzip::Reader`. The stream supplied to the
      # block responds to #read, #readpartial and #eof?, see `IOStreams::ChunkReader`.
      #
      # Parameters are passed through to `SymmetricEncryption::Reader`:
      #   buffer_size: [Integer]
      #     The number of bytes to read from the input stream at a time.
      #     Default: 16,384
      #
      #   version: [Integer]
      #     The version of the cipher to decrypt with, when the encrypted data has no header, which names it.
      #     Default: the primary cipher
      def self.stream(input_stream, buffer_size: 16_384, version: nil, &block)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(::SymmetricEncryption)

        begin
          reader = ::SymmetricEncryption::Reader.new(input_stream, buffer_size: buffer_size, version: version)
          io     = BlockReader.new(reader)
          !reader.eof? && reader.compressed? ? Gzip::Reader.stream(io, &block) : block.call(io)
        ensure
          reader&.close(false)
        end
      end
    end
  end
end
