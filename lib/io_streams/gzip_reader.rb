module RocketJob
  module Streams
    class GzipReader
      # Read from a gzip file or stream, decompressing the contents as it is read
      def self.open(file_name_or_io, _=nil, &block)
        if file_name_or_io.is_a?(String)
          ::Zlib::GzipReader.open(file_name_or_io, &block)
        else
          begin
            io = ::Zlib::GzipReader.new(file_name_or_io)
            block.call(io)
          ensure
            # TODO Look into issue when streams are chained and one closes it before
            #      the others are finished
            #io.close if io
          end
        end
      end

    end
  end
end