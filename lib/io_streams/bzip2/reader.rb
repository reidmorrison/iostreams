module IOStreams
  module Bzip2
    class Reader
      # Read from a Bzip2 file or stream, decompressing the contents as it is read
      def self.open(file_name_or_io, **args, &block)
        begin
          require 'rbzip2' unless defined?(RBzip2)
        rescue LoadError => e
          raise(LoadError, "Please install the 'rbzip2' gem for Bzip2 streaming support. #{e.message}")
        end

        if IOStreams.reader_stream?(file_name_or_io)
          begin
            io = RBzip2.default_adapter::Decompressor.new(file_name_or_io)
            block.call(io)
          ensure
            io.close if io && (io.respond_to?(:closed?) && !io.closed?)
          end
        else
          ::File.open(file_name_or_io, 'rb') do |file|
            io = RBzip2.default_adapter::Decompressor.new(file)
            block.call(io)
          end
        end

      end
    end
  end
end
