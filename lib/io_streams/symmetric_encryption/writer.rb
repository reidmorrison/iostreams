# frozen_string_literal: true

module IOStreams
  module SymmetricEncryption
    class Writer < IOStreams::Writer
      def self.option_names
        %i[compress version cipher_name header random_key random_iv]
      end

      # Write to stream using Symmetric Encryption
      # By default the output stream is compressed.
      # If the input_stream is already compressed consider setting compress: false.
      #
      # Like `SymmetricEncryption::Writer.open`, but does not close the output stream, which belongs to the caller.
      #
      # The data is compressed by the gzip stream, see `IOStreams::Gzip::Writer`, before it is encrypted. The last block
      # of the cipher is written when the block returns, including when it leaves early, such as with `break`. It is
      # not written when the block raises, or its thread is killed, so that the output cannot be decrypted as a
      # complete file of the partial data.
      def self.stream(output_stream, compress: true, **args, &block)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(::SymmetricEncryption)

        writer = ::SymmetricEncryption::Writer.new(output_stream, compress: compress, **args)
        Utils.finish_or_abort(finish: -> { writer.close(false) }) do
          compress ? Gzip::Writer.stream(writer, &block) : block.call(writer)
        end
      end

      # Write to stream using Symmetric Encryption
      # By default the output stream is compressed unless the file_name extension indicates the file is already compressed.
      def self.file(file_name, compress: nil, **args, &)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(::SymmetricEncryption)

        ::SymmetricEncryption::Writer.open(file_name, compress: compress, **args, &)
      end
    end
  end
end
