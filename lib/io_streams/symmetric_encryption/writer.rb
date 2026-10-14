# frozen_string_literal: true

module IOStreams
  module SymmetricEncryption
    class Writer < IOStreams::Writer
      def self.option_names
        %i[compress version cipher_name header random_key random_iv]
      end

      # Write to stream using Symmetric Encryption
      # By default the data is compressed before it is encrypted.
      # If the data is already compressed consider setting compress: false.
      #
      # Like `SymmetricEncryption::Writer.open`, but does not close the output stream, which belongs to the caller.
      #
      # The data is compressed by the gzip stream, see `IOStreams::Gzip::Writer`, before it is encrypted. The stream
      # supplied to the block responds to the methods of an IO that write, see `IOStreams::Writable`.
      #
      # The last block of the cipher is written when the block returns, including when it leaves early, such as with
      # `break`. It is not written when the block raises, or its thread is killed, so that the output cannot be
      # decrypted as a complete file of the partial data.
      #
      # Parameters are passed through to `SymmetricEncryption::Writer`, with the same defaults:
      #   compress: [true|false]
      #     Whether to compress the data before it is encrypted.
      #     Default: true
      #
      #   version: [Integer]
      #     The version of the cipher to encrypt with.
      #     Default: the primary cipher
      #
      #   cipher_name: [String]
      #     The name of the OpenSSL cipher to encrypt with, with a random key and IV.
      #     Default: the cipher of the version
      #
      #   header: [true|false]
      #     Whether to write a header, which records the cipher, the key and the IV, and whether the data is compressed.
      #     Default: true
      #
      #   random_key: [true|false]
      #     Whether to encrypt with a random key, which the header holds encrypted.
      #     Default: true
      #
      #   random_iv: [true|false]
      #     Whether to encrypt with a random IV, which the header holds.
      #     Default: true
      def self.stream(output_stream, compress: true, version: nil, cipher_name: nil, header: true, random_key: true,
                      random_iv: true, &block)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(::SymmetricEncryption)

        writer = ::SymmetricEncryption::Writer.new(
          output_stream,
          compress: compress, version: version, cipher_name: cipher_name, header: header, random_key: random_key,
          random_iv: random_iv
        )
        Utils.finish_or_abort(finish: -> { writer.close(false) }) do
          compress ? Gzip::Writer.stream(writer, &block) : block.call(Writable::Adapter.new(writer))
        end
      end
    end
  end
end
