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
      def self.stream(input_stream, buffer_size: 16_384, **args, &block)
        Utils.load_soft_dependency("symmetric-encryption", ".enc streaming") unless defined?(::SymmetricEncryption)

        begin
          reader = ::SymmetricEncryption::Reader.new(input_stream, buffer_size: buffer_size, **args)
          io     = BlockReader.new(reader)
          !reader.eof? && reader.compressed? ? Gzip::Reader.stream(io, &block) : block.call(io)
        ensure
          reader&.close(false)
        end
      end
    end
  end
end
