module RocketJob
  module Streams
    class Encryption
      # Options to be passed into this SymmetricEncryption stream
      def initialize(options={})
        @options = options
      end

      # Read from a file or stream, decrypting the contents as it is read
      def read(file_name_or_io, &block)
        SymmetricEncryption::Reader.open(file_name_or_io, @options, &block)
      end

      # Write to a file or stream, encrypting the contents as it is being written
      def write(file_name_or_io, &block)
        SymmetricEncryption::Writer.open(file_name_or_io, @options, &block)
      end
    end
  end
end