module IOStreams
  module Bzip2
    class Writer
      # Write to a file / stream, compressing with Bzip2
      def self.open(file_name_or_io, _=nil, &block)
        begin
          require 'rbzip2' unless defined?(RBzip2)
        rescue LoadError => e
          raise(LoadError, "Please install the 'rbzip2' gem for Bzip2 streaming support. #{e.message}")
        end

        if IOStreams.reader_stream?(file_name_or_io)
          begin
            io = RBzip2.default_adapter::Compressor.new(file_name_or_io)
            block.call(io)
          ensure
            io.close
          end
        else
          ::File.open(file_name_or_io, 'wb') do |file|
            io = RBzip2.default_adapter::Compressor.new(file)
            block.call(io)
            io.close
          end
        end

      end
    end
  end
end
