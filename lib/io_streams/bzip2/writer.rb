module IOStreams
  module Bzip2
    class Writer
      # Write to a file / stream, compressing with Bzip2
      def self.open(file_name_or_io, **args, &block)
        begin
          require 'rbzip2' unless defined?(RBzip2)
        rescue LoadError => e
          raise(LoadError, "Please install the 'rbzip2' gem for Bzip2 streaming support. #{e.message}")
        end

        if IOStreams.writer_stream?(file_name_or_io)
          begin
            io = RBzip2.default_adapter::Compressor.new(file_name_or_io)
            block.call(io)
          ensure
            io.close
          end
        else
          IOStreams::File::Writer.open(file_name_or_io) do |file|
            io = RBzip2.default_adapter::Compressor.new(file)
            block.call(io)
            io.close
          end
        end
      end
    end
  end
end
