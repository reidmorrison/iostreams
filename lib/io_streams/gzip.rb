module RocketJob
  module Streams
    class Gzip

      # Read from a gzip file or stream, decompressing the contents as it is read
      def read(file_name_or_io, &block)
        if file_name_or_io.is_a?(String)
          Zlib::GzipReader.open(file_name_or_io, &block)
        else
          begin
            io = Zlib::GzipReader.new(file_name_or_io)
            block.call(io)
          ensure
            io.close if io
          end
        end
      end

      # Write to a file / stream, compressing with GZip
      def write(file_name_or_io, &block)
        if file_name_or_io.is_a?(String)
          Zlib::GzipWriter.open(file_name_or_io, &block)
        else
          begin
            io = Zlib::GzipWriter.new(file_name_or_io)
            block.call(io)
          ensure
            io.close if io
          end
        end
      end

    end
  end
end