module IOStreams
  module SymmetricEncryption
    class Reader
      # read from a file/stream using Symmetric Encryption
      def self.open(file_name_or_io, **args, &block)
        begin
          require 'symmetric-encryption' unless defined?(SymmetricEncryption)
        rescue LoadError => e
          raise(LoadError, "Please install the 'symmetric-encryption' gem for .enc streaming support. #{e.message}")
        end

        if IOStreams.reader_stream?(file_name_or_io)
          ::SymmetricEncryption::Reader.open(file_name_or_io, **args, &block)
        else
          IOStreams::File::Reader.open(file_name_or_io) do |file|
            ::SymmetricEncryption::Reader.open(file, **args, &block)
          end
        end
      end
    end
  end
end
