module RocketJob
  module Streams
    class File

      # Read from a file or stream
      def read(file_name_or_io, &block)
        if file_name_or_io.is_a?(String)
          File.open(file_name_or_io, 'rb', &block)
        else
          block.call(file_name_or_io)
        end
      end

      # Write to a file or stream
      def write(file_name_or_io, &block)
        if is_file_name
          File.open(file_name_or_io, 'wb', &block)
        else
          block.call(file_name_or_io)
        end
      end

    end
  end
end