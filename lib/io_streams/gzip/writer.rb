module IOStreams
  module Gzip
    class Writer
      # Write to a file / stream, compressing with GZip
      def self.open(file_name_or_io, **args, &block)
        unless IOStreams.writer_stream?(file_name_or_io)
          IOStreams.mkpath(file_name_or_io)
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
