module IOStreams
  module SymmetricEncryption
    class Writer
      # Write to file/stream using Symmetric Encryption
      def self.open(file_name_or_io, compress: nil, **args, &block)
        begin
          require 'symmetric-encryption' unless defined?(SymmetricEncryption)
        rescue LoadError => e
          raise(LoadError, "Please install the 'symmetric-encryption' gem for .enc streaming support. #{e.message}")
        end

        if IOStreams.writer_stream?(file_name_or_io)
          compress = true if compress.nil?
          ::SymmetricEncryption::Writer.open(file_name_or_io, compress: compress, **args, &block)
        else
          compress = !IOStreams.compressed?(file_name_or_io) if compress.nil?

          IOStreams::File::Writer.open(file_name_or_io) do |file|
            ::SymmetricEncryption::Writer.open(file, compress: compress, **args, &block)
          end
        end
      end
    end
  end
end
