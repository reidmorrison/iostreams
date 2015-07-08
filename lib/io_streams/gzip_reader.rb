module RocketJob
  module Streams
    class GzipReader
      # Read from a gzip file or stream, decompressing the contents as it is read
      def self.open(file_name_or_io, _=nil, &block)
        unless file_name_or_io.respond_to?(:read)
          ::Zlib::GzipReader.open(file_name_or_io, &block)
        else
          begin
            io = ::Zlib::GzipReader.new(file_name_or_io)
            block.call(io)
          ensure
            io.close if io && (io.respond_to?(:closed?) && !io.closed?)
          end
        end
      end

    end
  end
end