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
      def self.stream(output_stream, compress: true, **args, &block)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(::SymmetricEncryption)

        writer = ::SymmetricEncryption::Writer.new(output_stream, compress: compress, **args)
        Utils.finish_or_abort(finish: -> { writer.close(false) }) do
          compress ? Gzip::Writer.stream(writer, &block) : block.call(Writable::Adapter.new(writer))
        end
      end
    end
  end
end
