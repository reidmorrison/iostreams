module IOStreams
  module Gzip
    class Writer
      # Write to a file / stream, compressing with GZip
      def self.open(file_name_or_io, _=nil, &block)
        unless file_name_or_io.respond_to?(:write)
          Zlib::GzipWriter.open(file_name_or_io, &block)
        else
          begin
            io = Zlib::GzipWriter.new(file_name_or_io)
            block.call(io)
          ensure
            io.close if io && (io.respond_to?(:closed?) && !io.closed?)
          end
        end
      end

    end
  end
end