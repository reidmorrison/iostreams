# frozen_string_literal: true

module IOStreams
  module SymmetricEncryption
    class Reader < IOStreams::Reader
      def self.option_names
        %i[buffer_size version]
      end

      # Returns [Module] the kind of failure that an exception of symmetric-encryption means, see
      # `IOStreams::Reader.failure_kind`: `IOStreams::Errors::MissingKey` for `SymmetricEncryption::CipherError`, which it
      # raises for data whose header names the version of a cipher that is not configured, and
      # `IOStreams::Errors::Corrupt` for `OpenSSL::Cipher::CipherError`, which the cipher raises for data that it cannot
      # decrypt: data that is not encrypted, or is damaged or cut short, or, since the cipher cannot tell them apart,
      # data that was encrypted with another key.
      def self.failure_kind(exception)
        return Errors::MissingKey if exception.is_a?(::SymmetricEncryption::CipherError)

        Errors::Corrupt if exception.is_a?(::OpenSSL::Cipher::CipherError)
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
      #
      # Raises `OpenSSL::Cipher::CipherError`, tagged as `IOStreams::Errors::Corrupt`, for data that the cipher cannot
      # decrypt, see .failure_kind, and the exception of the gzip stream for compressed data that it cannot decompress.
      def self.stream(input_stream, buffer_size: 16_384, version: nil, &block)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(::SymmetricEncryption)

        begin
          # Reads the header, and decrypts the key that it holds.
          reader     = tag_failure { ::SymmetricEncryption::Reader.new(input_stream, buffer_size: buffer_size, version: version) }
          io         = BlockReader.new(reader, failures: self)
          compressed = tag_failure { !reader.eof? && reader.compressed? }
          compressed ? Gzip::Reader.stream(io, &block) : block.call(io)
        ensure
          reader&.close(false)
        end
      end
    end
  end
end
