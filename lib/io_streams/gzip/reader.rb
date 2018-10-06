module IOStreams
  module Gzip
    class Reader
      # Read from a gzip file or stream, decompressing the contents as it is read
      def self.open(file_name_or_io, **args, &block)
        unless IOStreams.reader_stream?(file_name_or_io)
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
